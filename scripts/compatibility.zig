const std = @import("std");
const agent = @import("agent");

fn echo(_: ?*anyopaque, _: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    if (arguments != .object or arguments.object.get("n").?.integer != 41) return error.BadFixtureArguments;
    return .{ .text = "42" };
}

fn permission(_: ?*anyopaque, _: std.mem.Allocator, name: []const u8, _: std.json.Value) !agent.PermissionDecision {
    if (std.mem.eql(u8, name, "fixture_allow")) return .allow;
    return .{ .deny = "fixture denial" };
}

pub fn main(init: std.process.Init) !void {
    const path = init.environ_map.get("COMPATIBILITY_CLI") orelse return error.MissingFixture;
    const servers = [_]agent.McpServer{.{
        .name = "fixture",
        .tools = &.{.{ .name = "echo", .description = "Fixture echo", .handler = echo }},
    }};
    const client = try agent.Client.open(init.gpa, init.io, .{
        .claude_path = path,
        .sdk_mcp_servers = &servers,
        .permission_handler = permission,
        .resume_session_id = "sanitized-session",
    });
    defer _ = client.close();
    try client.send("fixture prompt");
    var initialized = false;
    var completed = false;
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        if (e.kind == .system and !initialized) {
            initialized = true;
            try client.interrupt();
        }
        if (e.kind == .result) {
            completed = true;
            client.closeStdin();
        }
    }
    if (!initialized or !completed) return error.IncompleteFixture;
    const term = try client.wait();
    if (term != .exited or term.exited != 0) return error.FixtureRejectedBehavior;
}
