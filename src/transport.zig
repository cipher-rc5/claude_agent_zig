// src/transport.zig
// Nonblocking POSIX pipes and child observation for bounded recovery.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const builtin = @import("builtin");

// A persistent byte broadcasts a terminal state to every poll waiter. These
// descriptors stay open until all client calls and their readiness tasks join.
pub const Wake = struct {
    files: [2]Io.File,

    pub fn init(io: Io) error{TransportFailed}!Wake {
        var fds: [2]posix.fd_t = undefined;
        if (posix.errno(posix.system.pipe(&fds)) != .SUCCESS) return error.TransportFailed;
        const wake: Wake = .{ .files = .{
            .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        } };
        errdefer wake.deinit(io);
        for (wake.files) |file| {
            try nonblocking(file);
            try closeOnExec(file);
        }
        return wake;
    }

    pub fn deinit(wake: Wake, io: Io) void {
        for (wake.files) |file| file.close(io);
    }

    pub fn signal(wake: *const Wake) void {
        const byte = [_]u8{1};
        while (true) {
            const rc = posix.system.write(wake.files[1].handle, &byte, byte.len);
            // EAGAIN means a byte is already present; all waiters will wake.
            if (posix.errno(rc) != .INTR) return;
        }
    }
};

pub const State = struct {
    stopped: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    stdin_closed: std.atomic.Value(bool) = .init(false),
    wake: ?Wake = null,

    pub fn init(io: Io) error{TransportFailed}!State {
        return .{ .wake = try .init(io) };
    }

    pub fn deinit(state: *State, io: Io) void {
        if (state.wake) |wake| wake.deinit(io);
    }

    pub fn stop(state: *State) void {
        state.stopped.store(true, .release);
        if (state.wake) |*wake| wake.signal();
    }

    pub fn fail(state: *State) void {
        state.failed.store(true, .release);
        if (state.wake) |*wake| wake.signal();
    }
};

fn closeOnExec(file: Io.File) error{TransportFailed}!void {
    if (posix.errno(posix.system.fcntl(file.handle, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS)
        return error.TransportFailed;
}

pub fn nonblocking(file: Io.File) error{TransportFailed}!void {
    const flags = posix.system.fcntl(file.handle, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(flags) != .SUCCESS) return error.TransportFailed;
    const nonblock: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
    if (posix.errno(posix.system.fcntl(file.handle, posix.F.SETFL, @as(usize, @intCast(flags)) | nonblock)) != .SUCCESS)
        return error.TransportFailed;
}

const Readiness = struct {
    io: Io,
    file: Io.File,
    wake: *const Wake,
    events: i16,
    deadline: ?Io.Timestamp,
    done: Io.Event = .unset,
    failed: bool = false,

    fn run(wait: *Readiness) void {
        var fds = [_]posix.pollfd{
            .{ .fd = wait.file.handle, .events = wait.events, .revents = 0 },
            .{ .fd = wait.wake.files[0].handle, .events = posix.POLL.IN, .revents = 0 },
        };
        const result = posix.system.poll(&fds, fds.len, remainingTimeout(wait.io, wait.deadline));
        wait.failed = switch (posix.errno(result)) {
            .SUCCESS, .INTR => false,
            else => true,
        };
        wait.done.set(wait.io);
    }
};

// Io.Event is a cancellation point; raw POSIX poll is not. A readiness task
// blocks in poll while the caller parks in the Io runtime. Cancellation wakes
// the task before joining it, so no background task can outlive its descriptors.
pub fn canPark(io: Io) bool {
    return io.vtable.concurrent == Io.Threaded.global_single_threaded.io().vtable.concurrent;
}

pub fn waitReady(io: Io, file: Io.File, events: i16, wake: ?*const Wake, deadline: ?Io.Timestamp) (error{WaitFailed} || Io.Cancelable)!void {
    try io.checkCancel();
    var timeout = remainingTimeout(io, deadline);
    if (timeout == 0) return;
    // Most pipe stalls resolve immediately as the peer writes its next chunk.
    // Probe once before allocating a task; an idle pipe then parks indefinitely.
    var fds = [_]posix.pollfd{
        .{ .fd = file.handle, .events = events, .revents = 0 },
        .{ .fd = if (wake) |w| w.files[0].handle else -1, .events = posix.POLL.IN, .revents = 0 },
    };
    const probe = posix.system.poll(&fds, fds.len, if (timeout < 0) 2 else @min(timeout, 2));
    switch (posix.errno(probe)) {
        .SUCCESS => if (probe > 0) return,
        .INTR => return,
        else => return error.WaitFailed,
    }
    timeout = remainingTimeout(io, deadline);
    if (timeout == 0) return;
    if (wake) |w| {
        // Evented runtimes may run concurrent functions as fibers. Raw poll
        // must not block their scheduler; only Threaded's worker pool is used.
        // The toolchain is pinned, and its public io() exposes this vtable.
        if (!canPark(io)) return;
        var wait: Readiness = .{ .io = io, .file = file, .wake = w, .events = events, .deadline = deadline };
        if (io.concurrent(Readiness.run, .{&wait})) |task| {
            var future = task;
            defer {
                const protection = io.swapCancelProtection(.blocked);
                defer _ = io.swapCancelProtection(protection);
                future.await(io);
            }
            wait.done.wait(io) catch |err| {
                w.signal();
                return err;
            };
            if (wait.failed) return error.WaitFailed;
            return;
        } else |_| {}
    }
    // A runtime without a spare concurrent task retains bounded cancellation.
    // Private fixtures without a wake descriptor use the same fallback.
    // The probe above already performed this fallback's bounded wait.
}

fn remainingTimeout(io: Io, deadline: ?Io.Timestamp) c_int {
    const limit = deadline orelse return -1;
    const remaining = limit.nanoseconds - Io.Clock.awake.now(io).nanoseconds;
    if (remaining <= 0) return 0;
    return @intCast(@min(std.math.maxInt(c_int), @divTrunc(remaining + 999_999, 1_000_000)));
}

/// Observe exit without reaping. Keeping the ready event queued lets every
/// waiter wake; `Client` still owns the single waitpid under its state lock.
pub fn watchChild(io: Io, pid: std.process.Child.Id) error{TransportFailed}!?Io.File {
    if (comptime builtin.os.tag == .macos) {
        const fd = posix.system.kqueue();
        if (fd < 0) return error.TransportFailed;
        const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        errdefer file.close(io);
        try closeOnExec(file);
        const change = [_]posix.Kevent{.{
            .ident = @intCast(pid),
            .filter = std.c.EVFILT.PROC,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = std.c.NOTE.EXIT,
            .data = 0,
            .udata = 0,
        }};
        const zero: posix.timespec = .{ .sec = 0, .nsec = 0 };
        var unused: [0]posix.Kevent = .{};
        const result = posix.system.kevent(fd, &change, change.len, &unused, 0, &zero);
        switch (posix.errno(result)) {
            .SUCCESS => return file,
            .SRCH => {
                file.close(io);
                return null; // Already exited; the next waitpid observes it.
            },
            else => return error.TransportFailed,
        }
    } else return null;
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
                w.state.fail();
                return error.WriteFailed;
            }
            const n = posix.system.write(w.file.handle, rest.ptr, @min(rest.len, 64 * 1024));
            switch (posix.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return w.fail();
                    rest = rest[@intCast(n)..];
                },
                .INTR => continue,
                .AGAIN => waitReady(w.io, w.file, posix.POLL.OUT, if (w.state.wake) |*wake| wake else null, w.deadline) catch return w.fail(),
                else => return w.fail(),
            }
        }
    }

    fn fail(w: *Writer) Io.Writer.Error {
        w.state.fail();
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
            self.io.checkCancel() catch {
                self.state.fail();
                return error.ReadFailed;
            };
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
                .AGAIN => waitReady(self.io, self.file, posix.POLL.IN, if (self.state.wake) |*wake| wake else null, null) catch {
                    self.state.fail();
                    return error.ReadFailed;
                },
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
            // Another reaper consumed the child; never signal this PID again.
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

// `Reader`, `Writer`, and pipe helpers are internal to this module.

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

test "a readiness task starting after its deadline completes without waiting for pipe activity" {
    const io = std.testing.io;
    const pair = try testPipe();
    defer for (pair) |file| file.close(io);
    const wake = try Wake.init(io);
    defer wake.deinit(io);
    const deadline = Io.Clock.awake.now(io);
    var task: Readiness = .{ .io = io, .file = pair[0], .wake = &wake, .events = posix.POLL.IN, .deadline = deadline };
    const start = Io.Clock.awake.now(io);
    task.run();
    try std.testing.expect(!task.failed);
    try std.testing.expectEqual(Io.Event.is_set, task.done);
    try std.testing.expect(start.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 100);
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
