// examples/streaming.zig
// Streams one foreground turn and checks the child's exit status.

const std = @import("std");
const agent = @import("agent");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const prompt = args.next() orelse "Summarize README.md";
    const client = try agent.Client.open(init.gpa, init.io, .{
        .claude_path = init.environ_map.get("CLAUDE_BIN") orelse "claude",
        .tools = "Read,Glob,Grep",
        .allowed_tools = "Read,Glob,Grep",
        .max_turns = 3,
    });
    defer {
        _ = client.terminate(250) catch {};
        _ = client.close();
    }

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try client.send(prompt);
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        if (e.textDelta()) |text| {
            try stdout.interface.writeAll(text);
            try stdout.interface.flush();
        }
        if (e.kind == .result) client.closeStdin();
    }
    switch (try client.wait()) {
        .exited => |code| if (code != 0) return error.AgentFailed,
        else => return error.AgentFailed,
    }
}
