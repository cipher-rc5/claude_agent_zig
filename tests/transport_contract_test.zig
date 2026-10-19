// tests/transport_contract_test.zig
// Public transport contracts under backpressure and fragmented I/O.

const std = @import("std");
const agent = @import("agent");
const io = std.testing.io;
const gpa = std.testing.allocator;

const Stub = struct {
    dir: std.testing.TmpDir,
    path: [:0]u8,

    fn init(script: []const u8) !Stub {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        try dir.dir.writeFile(io, .{
            .sub_path = "stub.sh",
            .data = script,
            .flags = .{ .permissions = .executable_file },
        });
        return .{ .dir = dir, .path = try dir.dir.realPathFileAlloc(io, "stub.sh", gpa) };
    }

    fn deinit(self: *Stub) void {
        gpa.free(self.path);
        self.dir.cleanup();
    }

    fn open(self: *const Stub, options: agent.Options) !*agent.Client {
        var configured = options;
        configured.claude_path = self.path;
        return agent.Client.open(gpa, io, configured);
    }
};

const ReadTask = struct {
    client: *agent.Client,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn run(self: *ReadTask) void {
        defer self.done.store(true, .release);
        var event = self.client.next() catch |err| {
            self.failure = err;
            return;
        } orelse return;
        event.deinit();
    }
};

test "transport contract: a failed send releases a reader without termination" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\trap '' TERM
        \\printf '{"type":"system","subtype":"ready"}\n'
        \\exec sleep 3
        \\
    );
    defer stub.deinit();
    const client = try stub.open(.{ .write_timeout_ms = 30 });
    defer _ = client.close();
    var ready = (try client.next()).?;
    defer ready.deinit();

    var task: ReadTask = .{ .client = client };
    const thread = try std.Thread.spawn(.{}, ReadTask.run, .{&task});
    defer {
        _ = client.forceKill() catch {};
        thread.join();
    }
    const payload = try gpa.alloc(u8, 2 * 1024 * 1024);
    defer gpa.free(payload);
    @memset(payload, 'x');
    try std.testing.expectError(error.WriteTimedOut, client.send(payload));

    const start = std.Io.Clock.awake.now(io);
    while (!task.done.load(.acquire)) {
        if (start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 1_000) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(task.done.load(.acquire));
    try std.testing.expectEqual(error.TransportFailed, task.failure.?);
    try std.testing.expect(client.status().transport_failed);
}

const WriteTask = struct {
    client: *agent.Client,
    payload: []const u8,
    failure: ?anyerror = null,

    fn run(self: *WriteTask) void {
        self.client.send(self.payload) catch |err| {
            self.failure = err;
        };
    }
};

test "transport contract: forceKill bypasses a writer holding the write lock" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\trap '' TERM
        \\dd bs=1 count=1 >/dev/null 2>&1
        \\printf '{"type":"system","subtype":"writing"}\n'
        \\exec sleep 3
        \\
    );
    defer stub.deinit();
    const client = try stub.open(.{ .write_timeout_ms = 3_000 });
    defer _ = client.close();
    const payload = try gpa.alloc(u8, 2 * 1024 * 1024);
    defer gpa.free(payload);
    @memset(payload, 'x');
    var task: WriteTask = .{ .client = client, .payload = payload };
    const thread = try std.Thread.spawn(.{}, WriteTask.run, .{&task});
    defer {
        _ = client.forceKill() catch {};
        thread.join();
    }

    var ready = (try client.next()).?;
    defer ready.deinit();
    try std.testing.expectEqualStrings("writing", ready.subtype().?);
    const start = std.Io.Clock.awake.now(io);
    const term = try client.forceKill();
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(elapsed < 1_500);
    try std.testing.expectEqual(agent.Term{ .signal = std.posix.SIG.KILL }, term);
    try std.testing.expect(client.status().force_killed);
}

test "transport contract: one-byte buffers preserve escaped user messages" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\IFS= read -r line || exit 1
        \\printf '{"type":"system","sent":%s}\n' "$line"
        \\exit 0
        \\
    );
    defer stub.deinit();
    const client = try stub.open(.{ .stdin_buffer_size = 1, .stdout_buffer_size = 1 });
    defer _ = client.close();
    const text = "one-byte \"quoted\"\n\t\\fragment\x00";
    try client.send(text);
    var event = (try client.next()).?;
    defer event.deinit();
    const turn = event.root().object.get("sent").?.object.get("message").?;
    const actual = turn.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings(text, actual);
    try std.testing.expect(try client.next() == null);
    try std.testing.expectEqual(agent.Term{ .exited = 0 }, try client.wait());
}
