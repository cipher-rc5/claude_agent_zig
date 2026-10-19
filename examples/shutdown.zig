// examples/shutdown.zig
// Gives a foreground turn 30 seconds, then terminates and joins the reader.

const std = @import("std");
const agent = @import("agent");

const Reader = struct {
    client: *agent.Client,
    failure: ?anyerror = null,

    fn run(self: *Reader) void {
        self.read() catch |err| {
            self.failure = err;
            _ = self.client.terminate(250) catch {};
        };
    }

    fn read(self: *Reader) !void {
        while (try self.client.next()) |event| {
            var e = event;
            defer e.deinit();
            if (e.kind == .result) self.client.closeStdin();
        }
        _ = try self.client.wait();
    }
};

pub fn main(init: std.process.Init) !void {
    const client = try agent.Client.open(init.gpa, init.io, .{
        .claude_path = init.environ_map.get("CLAUDE_BIN") orelse "claude",
        .tools = "Read,Glob,Grep",
        .allowed_tools = "Read,Glob,Grep",
        .write_timeout_ms = 1000,
        .max_turns = 3,
    });
    defer {
        _ = client.terminate(250) catch {};
        _ = client.close();
    }
    try client.send("Summarize this repository.");

    var reader: Reader = .{ .client = client };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    var joined = false;
    defer if (!joined) {
        _ = client.terminate(250) catch {};
        thread.join();
    };
    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    while (client.status().term == null) {
        if (start.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.toMilliseconds() >= 30_000) break;
        try init.io.sleep(.fromMilliseconds(50), .awake);
    }
    const timed_out = client.status().term == null;
    const term = try client.terminate(250);
    thread.join();
    joined = true;
    if (timed_out) return error.TurnTimedOut;
    if (reader.failure) |err| return err;
    switch (term) {
        .exited => |code| if (code != 0) return error.AgentFailed,
        else => return error.AgentFailed,
    }
}
