// tests/options_test.zig
// Black-box tests for the option types on the public surface.
//
// The `buildArgv` tests are deliberately not here. `buildArgv` is `pub` in
// options.zig so client.zig can call it, but it is not re-exported by
// agent.zig, so it is not public API — and re-exporting it purely to relocate
// a test would widen the public surface.

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
