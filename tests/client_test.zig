// tests/client_test.zig
// Black-box tests for the public shape of `Client`.
//
// The read-loop and control-dispatch tests stay in src/client.zig: they drive
// `readLine`, `writeCommandMessage`, and `serveControlRequest`, all private.

const std = @import("std");
const agent = @import("agent");

test "the write API declares an explicit error set" {
    // Inferred sets resolve through std.json.Stringify, so a stdlib change
    // would silently widen the public surface. Pin the three signatures.
    const Fn = @typeInfo(@TypeOf(agent.Client.send)).@"fn";
    try std.testing.expectEqual(agent.WriteError!void, Fn.return_type.?);
    try std.testing.expectEqual(
        agent.WriteError!void,
        @typeInfo(@TypeOf(agent.Client.sendCommand)).@"fn".return_type.?,
    );
    try std.testing.expectEqual(
        agent.WriteError!void,
        @typeInfo(@TypeOf(agent.Client.interrupt)).@"fn".return_type.?,
    );
    // StdinClosed is what a post-closeStdin write reports instead of landing
    // on a stale descriptor, so it has to stay in the set. Coercing it is a
    // compile error if it is ever dropped.
    const closed: agent.WriteError = error.StdinClosed;
    try std.testing.expectEqual(agent.WriteError.StdinClosed, closed);
}

test "the public surface re-exports every type a caller needs" {
    // agent.zig is the single public surface, so a caller should never need a
    // second import. Referencing each name here fails the build if one is
    // dropped or renamed.
    try std.testing.expect(@TypeOf(agent.Options) == type);
    try std.testing.expect(@TypeOf(agent.PermissionMode) == type);
    try std.testing.expect(@TypeOf(agent.Event) == type);
    try std.testing.expect(@TypeOf(agent.Kind) == type);
    try std.testing.expect(@TypeOf(agent.Tool) == type);
    try std.testing.expect(@TypeOf(agent.ToolHandler) == type);
    try std.testing.expect(@TypeOf(agent.ToolResult) == type);
    try std.testing.expect(@TypeOf(agent.McpServer) == type);
    try std.testing.expect(@TypeOf(agent.Client) == type);
    try std.testing.expect(@TypeOf(agent.OpenError) == type);
    try std.testing.expect(@TypeOf(agent.ReadError) == type);
    try std.testing.expect(@TypeOf(agent.WriteError) == type);
}
