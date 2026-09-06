// tests/options_test.zig
// Black-box tests for the option types on the public surface.
//
// The `buildArgv` tests are deliberately not here. `buildArgv` is `pub` in
// options.zig so client.zig can call it, but it is not re-exported by
// agent.zig, so it is not public API — and re-exporting it purely to relocate
// a test would widen the public surface. That includes the fact that
// `permission_handler` emits `--permission-prompt-tool stdio` and
// `--permission-prompts host`: the argv is not observable from here, so only
// what `Options` itself promises is pinned.

const std = @import("std");
const agent = @import("agent");

test "initialize is needed only for sdk servers or a skill allowlist" {
    const servers = [_]agent.McpServer{.{ .name = "host" }};
    try std.testing.expect(!(agent.Options{}).needsInitialize());
    try std.testing.expect((agent.Options{ .sdk_mcp_servers = &servers }).needsInitialize());
    // An empty allowlist still has to be declared, so it counts.
    try std.testing.expect((agent.Options{ .skills = &.{} }).needsInitialize());
}

test "permission modes render the exact spellings the CLI accepts" {
    // The CLI matches these verbatim, so the camelCase ones are load-bearing.
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
    // `just canary` parses this out of src/options.zig with sed and feeds it
    // to `sort -V`, so its shape is a contract with a shell script: three
    // decimal parts, dots between, nothing else. A pre-release suffix or a
    // leading `v` would compare wrongly there without failing anything here.
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
    // Null by default, so a session that never mentions permissions keeps
    // the CLI's own behaviour. The context pointer follows the handler and
    // means nothing without one.
    const defaults: agent.Options = .{};
    try std.testing.expect(defaults.permission_handler == null);
    try std.testing.expect(defaults.permission_context == null);

    // A plain `fn` coerces into the field, which is how a caller installs
    // one. The handshake rule for it is pinned separately below.
    var marker: u8 = 0;
    const with_handler: agent.Options = .{
        .permission_handler = allowEverything,
        .permission_context = &marker,
    };
    try std.testing.expect(with_handler.permission_handler != null);
}

test "a permission decision is one of allow, allow with input, or deny" {
    // The three shapes the CLI reply can take, each constructible from the
    // public surface. A switch with no `else` is what pins the set: adding a
    // variant fails to compile here, which is the intended reminder to
    // document its wire shape.
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
    // The CLI routes prompts to a host that has opened with `initialize`, as
    // the official SDK does; a handler with no servers and no skill list must
    // therefore still trigger it, or the first prompt is blocked instead of
    // dispatched.
    try std.testing.expect((agent.Options{ .permission_handler = allowEverything }).needsInitialize());
    try std.testing.expect(!(agent.Options{}).needsInitialize());
}
