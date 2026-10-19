// src/transport.zig
// Nonblocking POSIX pipes and child observation for bounded recovery.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;

pub const State = struct {
    stopped: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    stdin_closed: std.atomic.Value(bool) = .init(false),
};

pub fn nonblocking(file: Io.File) error{TransportFailed}!void {
    const flags = posix.system.fcntl(file.handle, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(flags) != .SUCCESS) return error.TransportFailed;
    const nonblock: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    if (posix.errno(posix.system.fcntl(file.handle, posix.F.SETFL, @as(usize, @intCast(flags)) | nonblock)) != .SUCCESS)
        return error.TransportFailed;
}

fn waitReady(file: Io.File, events: i16) error{WaitFailed}!void {
    var fds = [_]posix.pollfd{.{ .fd = file.handle, .events = events, .revents = 0 }};
    const result = posix.system.poll(&fds, 1, 2);
    switch (posix.errno(result)) {
        .SUCCESS, .INTR => {},
        else => return error.WaitFailed,
    }
}

pub const Writer = struct {
    file: Io.File,
    io: Io,
    state: *State,
    timeout_ms: u32,
    deadline: Io.Timestamp = .zero,
    timed_out: bool = false,
    interface: Io.Writer,

    pub fn init(file: Io.File, io: Io, state: *State, buffer: []u8, timeout_ms: u32) Writer {
        return .{ .file = file, .io = io, .state = state, .timeout_ms = timeout_ms, .interface = .{ .buffer = buffer, .vtable = &.{ .drain = drain } } };
    }

    pub fn begin(w: *Writer) void {
        w.deadline = Io.Clock.awake.now(w.io).addDuration(.fromMilliseconds(w.timeout_ms));
        w.timed_out = false;
    }

    fn writeAll(w: *Writer, bytes: []const u8) Io.Writer.Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            w.io.checkCancel() catch return w.fail();
            if (w.state.stopped.load(.acquire) or w.state.failed.load(.acquire)) return error.WriteFailed;
            if (Io.Clock.awake.now(w.io).nanoseconds >= w.deadline.nanoseconds) {
                w.timed_out = true;
                w.state.failed.store(true, .release);
                return error.WriteFailed;
            }
            const n = posix.system.write(w.file.handle, rest.ptr, @min(rest.len, 64 * 1024));
            switch (posix.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return w.fail();
                    rest = rest[@intCast(n)..];
                },
                .INTR => continue,
                .AGAIN => waitReady(w.file, posix.POLL.OUT) catch return w.fail(),
                else => return w.fail(),
            }
        }
    }

    fn fail(w: *Writer) Io.Writer.Error {
        w.state.failed.store(true, .release);
        return error.WriteFailed;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        try self.writeAll(w.buffered());
        w.end = 0;
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.writeAll(bytes);
            total += bytes.len;
        }
        for (0..splat) |_| {
            try self.writeAll(data[data.len - 1]);
            total += data[data.len - 1].len;
        }
        return total;
    }
};

pub const Reader = struct {
    file: Io.File,
    io: Io,
    state: *State,
    interface: Io.Reader,

    pub fn init(file: Io.File, io: Io, state: *State, buffer: []u8) Reader {
        return .{ .file = file, .io = io, .state = state, .interface = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &.{ .stream = stream, .readVec = readVec } } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const count = try readVec(r, &data);
        w.advance(count);
        return count;
    }

    fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", r));
        const use_buffer = r.buffer.len - r.end > data[0].len;
        const dest = if (use_buffer) r.buffer[r.end..] else data[0];
        while (true) {
            self.io.checkCancel() catch return error.ReadFailed;
            if (self.state.stopped.load(.acquire)) return error.EndOfStream;
            if (self.state.failed.load(.acquire)) return error.ReadFailed;
            const n = posix.system.read(self.file.handle, dest.ptr, dest.len);
            switch (posix.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return error.EndOfStream;
                    if (use_buffer) {
                        r.end += @intCast(n);
                        return 0;
                    }
                    return @intCast(n);
                },
                .INTR => continue,
                .AGAIN => waitReady(self.file, posix.POLL.IN) catch return error.ReadFailed,
                else => return error.ReadFailed,
            }
        }
    }
};

/// The caller holds the same lock used to signal and publish the result.
pub fn pollChild(child: *std.process.Child) std.process.Child.WaitError!?std.process.Child.Term {
    var status: if (@import("builtin").link_libc) c_int else i32 = undefined;
    while (true) {
        const result = posix.system.waitpid(child.id.?, &status, posix.W.NOHANG);
        switch (posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return null;
                child.id = null;
                const bits: u32 = @bitCast(status);
                return if (posix.W.IFEXITED(bits)) .{ .exited = posix.W.EXITSTATUS(bits) } else if (posix.W.IFSIGNALED(bits)) .{ .signal = posix.W.TERMSIG(bits) } else if (posix.W.IFSTOPPED(bits)) .{ .stopped = posix.W.STOPSIG(bits) } else .{ .unknown = bits };
            },
            .INTR => continue,
            // ECHILD means another host reaper consumed this child. Never signal
            // that numeric pid again.
            .CHILD => {
                child.id = null;
                return error.Unexpected;
            },
            .ACCES => return error.AccessDenied,
            else => return error.Unexpected,
        }
    }
}

// --- tests ---

fn testPipe() ![2]Io.File {
    var fds: [2]posix.fd_t = undefined;
    if (posix.errno(posix.system.pipe(&fds)) != .SUCCESS) return error.PipeFailed;
    const pair = [2]Io.File{
        .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
        .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
    };
    errdefer for (pair) |file| file.close(std.testing.io);
    for (pair) |file| try nonblocking(file);
    return pair;
}

test "writer preserves buffered bytes and repeated slices through a pipe" {
    const pair = try testPipe();
    defer for (pair) |file| file.close(std.testing.io);
    var state: State = .{};
    var buffer: [3]u8 = undefined;
    var writer = Writer.init(pair[1], std.testing.io, &state, &buffer, 100);
    writer.begin();
    try writer.interface.writeAll("ab");
    _ = try writer.interface.vtable.drain(&writer.interface, &.{ "cd", "xy" }, 3);
    try writer.interface.flush();
    var actual: [10]u8 = undefined;
    const count = posix.system.read(pair[0].handle, &actual, actual.len);
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(count));
    try std.testing.expectEqualStrings("abcdxyxyxy", actual[0..@intCast(count)]);
}

test "full pipe reaches its write deadline and preserves terminal failure" {
    const pair = try testPipe();
    defer for (pair) |file| file.close(std.testing.io);
    var state: State = .{};
    var writer = Writer.init(pair[1], std.testing.io, &state, &.{}, 20);
    writer.begin();
    const chunk: [64 * 1024]u8 = @splat('x');
    while (true) writer.interface.writeAll(&chunk) catch break;
    try std.testing.expect(writer.timed_out);
    try std.testing.expect(state.failed.load(.acquire));
    writer.begin();
    try std.testing.expectError(error.WriteFailed, writer.interface.writeAll("later"));
}

test "reader fills small buffers and observes terminal state without touching the fd" {
    const pair = try testPipe();
    defer for (pair) |file| file.close(std.testing.io);
    const bytes = "first\nsecond\n";
    try std.testing.expectEqual(posix.E.SUCCESS, posix.errno(posix.system.write(pair[1].handle, bytes.ptr, bytes.len)));
    var state: State = .{};
    var buffer: [1]u8 = undefined;
    var reader = Reader.init(pair[0], std.testing.io, &state, &buffer);
    var actual: [bytes.len]u8 = undefined;
    try reader.interface.readSliceAll(&actual);
    try std.testing.expectEqualStrings(bytes, &actual);
    state.failed.store(true, .release);
    try std.testing.expectError(error.ReadFailed, reader.interface.takeByte());
    state.stopped.store(true, .release);
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
}
