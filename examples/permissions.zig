// examples/permissions.zig
// Allows read prompts and denies other tools during one foreground turn.

const std = @import("std");
const agent = @import("agent");

fn decide(_: ?*anyopaque, _: std.mem.Allocator, name: []const u8, _: std.json.Value) !agent.PermissionDecision {
    if (std.mem.eql(u8, name, "Read")) return .allow;
    return .{ .deny = "Only Read is allowed; inspect files without running commands." };
}

pub fn main(init: std.process.Init) !void {
    const client = try agent.Client.open(init.gpa, init.io, .{
        .claude_path = init.environ_map.get("CLAUDE_BIN") orelse "claude",
        .tools = "Read,Bash",
        .permission_mode = .manual,
        .permission_handler = decide,
        .max_turns = 3,
    });
    defer {
        _ = client.terminate(250) catch {};
        _ = client.close();
    }

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try client.send("Read README.md and summarize it. Do not change any files.");
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        if (e.textDelta()) |text| try stdout.interface.writeAll(text);
        if (e.kind == .result) client.closeStdin();
    }
    try stdout.interface.flush();
    switch (try client.wait()) {
        .exited => |code| if (code != 0) return error.AgentFailed,
        else => return error.AgentFailed,
    }
}
