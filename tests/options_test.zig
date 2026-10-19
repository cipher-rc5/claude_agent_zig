// tests/options_test.zig
// Public option tests; internal buildArgv tests stay in src/options.zig.

const std = @import("std");
const agent = @import("agent");

test "initialize is needed only for sdk servers or a skill allowlist" {
    const servers = [_]agent.McpServer{.{ .name = "host" }};
    try std.testing.expect(!(agent.Options{}).needsInitialize());
    try std.testing.expect((agent.Options{ .sdk_mcp_servers = &servers }).needsInitialize());
    try std.testing.expect((agent.Options{ .skills = &.{} }).needsInitialize());
}

test "permission modes render the exact spellings the CLI accepts" {
    try std.testing.expectEqualStrings("manual", agent.PermissionMode.manual.cliName());
    try std.testing.expectEqualStrings("auto", agent.PermissionMode.auto.cliName());
    try std.testing.expectEqualStrings("dontAsk", agent.PermissionMode.dont_ask.cliName());
    try std.testing.expectEqualStrings("acceptEdits", agent.PermissionMode.accept_edits.cliName());
    try std.testing.expectEqualStrings(
        "bypassPermissions",
        agent.PermissionMode.bypass_permissions.cliName(),
    );
    try std.testing.expectEqualStrings("plan", agent.PermissionMode.plan.cliName());
}

test "min_cli_version is a dotted three-part version" {
    const version: []const u8 = agent.min_cli_version;
    try std.testing.expect(version.len > 0);

    var parts = std.mem.splitScalar(u8, version, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        try std.testing.expect(part.len > 0);
        _ = try std.fmt.parseInt(u32, part, 10);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

fn allowEverything(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
) anyerror!agent.PermissionDecision {
    return .allow;
}

test "permission prompts stay with the CLI unless a handler is installed" {
    const defaults: agent.Options = .{};
    try std.testing.expect(defaults.permission_handler == null);
    try std.testing.expect(defaults.permission_context == null);

    var marker: u8 = 0;
    const with_handler: agent.Options = .{
        .permission_handler = allowEverything,
        .permission_context = &marker,
    };
    try std.testing.expect(with_handler.permission_handler != null);
}

test "a permission decision is one of allow, allow with input, or deny" {
    const decisions = [_]agent.PermissionDecision{
        .allow,
        .{ .allow_with_input = "{\"command\":\"ls -la\"}" },
        .{ .deny = "use Read instead" },
    };
    for (decisions, 0..) |decision, i| {
        switch (decision) {
            .allow => try std.testing.expectEqual(@as(usize, 0), i),
            .allow_with_input => |raw| {
                try std.testing.expectEqual(@as(usize, 1), i);
                try std.testing.expect(std.mem.startsWith(u8, raw, "{"));
            },
            .deny => |message| {
                try std.testing.expectEqual(@as(usize, 2), i);
                try std.testing.expectEqualStrings("use Read instead", message);
            },
        }
    }
}

test "a permission handler alone is enough to need the initialize handshake" {
    try std.testing.expect((agent.Options{ .permission_handler = allowEverything }).needsInitialize());
    try std.testing.expect(!(agent.Options{}).needsInitialize());
}

test "bounded I/O defaults are explicit" {
    const defaults: agent.Options = .{};
    try std.testing.expectEqual(@as(u32, 5_000), defaults.write_timeout_ms);
    try std.testing.expectEqual(@as(u32, 250), defaults.termination_grace_ms);
}
