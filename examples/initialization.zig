// examples/initialization.zig
// Reports initialization rejection during one foreground turn.

const std = @import("std");
const agent = @import("agent");

pub fn main(init: std.process.Init) !void {
    const client = try agent.Client.open(init.gpa, init.io, .{
        .claude_path = init.environ_map.get("CLAUDE_BIN") orelse "claude",
        .skills = &.{},
        .tools = "Read",
        .allowed_tools = "Read",
        .max_turns = 1,
    });
    defer {
        _ = client.terminate(250) catch {};
        _ = client.close();
    }

    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    try client.send("Read README.md and give a one-sentence summary.");
    while (true) {
        const event = client.next() catch |err| switch (err) {
            error.InitializationRejected => {
                try stderr.interface.print("Initialization rejected: {s}\n", .{client.lastControlError() orelse "no detail"});
                try stderr.interface.flush();
                return err;
            },
            error.ControlRequestRejected => {
                try stderr.interface.print("Interrupt rejected: {s}\n", .{client.lastControlError() orelse "no detail"});
                try stderr.interface.flush();
                continue;
            },
            else => return err,
        } orelse break;
        var e = event;
        defer e.deinit();
        if (e.kind == .result) client.closeStdin();
    }
    if (client.status().initialization != .accepted) return error.InitializationNotAccepted;
    switch (try client.wait()) {
        .exited => |code| if (code != 0) return error.AgentFailed,
        else => return error.AgentFailed,
    }
}
