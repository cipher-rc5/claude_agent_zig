// tests/client_test.zig
// Black-box tests for the public shape of `Client`.
//
// The read-loop and control-dispatch tests stay in src/client.zig: they drive
// `readLine`, `writeCommandMessage`, and `serveControlRequest`, all private.

const std = @import("std");
const agent = @import("agent");

fn returnType(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

test "the write API declares an explicit error set" {
    // Inferred sets resolve through std.json.Stringify, so a stdlib change
    // would silently widen the public surface. Pin the three signatures.
    try std.testing.expectEqual(agent.WriteError!void, returnType(agent.Client.send));
    try std.testing.expectEqual(agent.WriteError!void, returnType(agent.Client.sendCommand));
    try std.testing.expectEqual(agent.WriteError!void, returnType(agent.Client.interrupt));

    // StdinClosed is what a post-closeStdin write reports instead of landing
    // on a stale descriptor, so it has to stay in the set. Coercing it is a
    // compile error if it is ever dropped.
    const closed: agent.WriteError = error.StdinClosed;
    try std.testing.expectEqual(agent.WriteError.StdinClosed, closed);

    // Exactly two members. No write path allocates, so an `OutOfMemory` here
    // would mean a write started buffering somewhere it should not, and the
    // README's description of the set would be wrong.
    const members = [_]agent.WriteError{ error.StdinClosed, error.WriteFailed };
    try std.testing.expectEqual(members.len, @typeInfo(agent.WriteError).error_set.?.len);
}

test "the read and open APIs declare their error sets" {
    try std.testing.expectEqual(agent.OpenError!*agent.Client, returnType(agent.Client.open));
    try std.testing.expectEqual(agent.ReadError!?agent.Event, returnType(agent.Client.next));
    try std.testing.expectEqual(agent.WaitError!agent.Term, returnType(agent.Client.wait));
    try std.testing.expectEqual(agent.Term, returnType(agent.Client.close));

    // Each of these is documented as a distinct outcome a caller can switch
    // on, so coercing each into its set is a compile error if one is dropped
    // or moves. `ReadError` is pinned exactly, like `WriteError` above: a
    // caller's exhaustive switch breaks on a new member, so one should not
    // arrive unnoticed. `OpenError` folds in the stdlib's spawn errors and
    // is checked for the members this library adds.
    const read_members = [_]agent.ReadError{
        error.ControlRequestRejected,
        error.InvalidJson,
        error.ProtocolTooLong,
        error.StdinClosed,
        error.ReadFailed,
        error.WriteFailed,
        // The read side does allocate: every event is a parsed tree.
        error.OutOfMemory,
    };
    try std.testing.expectEqual(read_members.len, @typeInfo(agent.ReadError).error_set.?.len);
    try std.testing.expectEqual(agent.ReadError.ControlRequestRejected, read_members[0]);

    const open_members = [_]agent.OpenError{
        error.InvalidToolSchema,
        error.InvalidMaxLineBytes,
        error.OutOfMemory,
        // From `std.process.SpawnError`: what a wrong `claude_path` reports.
        error.FileNotFound,
    };
    try std.testing.expectEqual(agent.OpenError.InvalidToolSchema, open_members[0]);
}

test "the public surface re-exports every type a caller needs" {
    // agent.zig is the single public surface, so a caller should never need a
    // second import. Referencing each name fails the build if one is dropped
    // or renamed; the shape checks fail if a name is rebound to the wrong
    // thing, which `@TypeOf(x) == type` never would.
    try std.testing.expect(@typeInfo(agent.Options) == .@"struct");
    try std.testing.expect(@typeInfo(agent.PermissionMode) == .@"enum");
    try std.testing.expect(@typeInfo(agent.Event) == .@"struct");
    try std.testing.expect(@typeInfo(agent.Kind) == .@"enum");
    try std.testing.expect(@typeInfo(agent.Tool) == .@"struct");
    try std.testing.expect(@typeInfo(agent.ToolResult) == .@"struct");
    try std.testing.expect(@typeInfo(agent.McpServer) == .@"struct");
    try std.testing.expect(@typeInfo(agent.Client) == .@"struct");
    try std.testing.expect(@typeInfo(agent.PermissionDecision) == .@"union");
    try std.testing.expect(@typeInfo(agent.OpenError) == .error_set);
    try std.testing.expect(@typeInfo(agent.ReadError) == .error_set);
    try std.testing.expect(@typeInfo(agent.WriteError) == .error_set);

    // Both handlers are pointers to functions, so a caller can pass a plain
    // `fn` and have it coerce, and each takes the arguments its doc comment
    // lists: context, arena, arguments for a tool; the same plus the tool
    // name for a permission prompt.
    const tool_fn = @typeInfo(agent.ToolHandler).pointer.child;
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(tool_fn).@"fn".params.len);
    try std.testing.expectEqual(anyerror!agent.ToolResult, @typeInfo(tool_fn).@"fn".return_type.?);
    const permission_fn = @typeInfo(agent.PermissionHandler).pointer.child;
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(permission_fn).@"fn".params.len);
    try std.testing.expectEqual(
        anyerror!agent.PermissionDecision,
        @typeInfo(permission_fn).@"fn".return_type.?,
    );

    // `Term` and `WaitError` exist so a caller naming `wait`'s result does
    // not need `std.process` for it, which only holds if they are the same
    // types the stdlib returns.
    try std.testing.expect(agent.Term == std.process.Child.Term);
    try std.testing.expect(agent.WaitError == std.process.Child.WaitError);

    // The constants keep the types their documentation promises: a byte
    // count a caller can compare a `[]const u8` length against, and a
    // version string it can print.
    try std.testing.expect(@TypeOf(agent.max_tool_result_bytes) == usize);
    try std.testing.expect(agent.max_tool_result_bytes > 0);
    const version: []const u8 = agent.min_cli_version;
    try std.testing.expect(version.len > 0);
}

test "Kind names every wire type the client dispatches on, plus unknown" {
    // `unknown` is what absorbs a wire type this enum does not name, which is
    // why `Kind` can stay exhaustive; if it went, every future CLI event type
    // would be a parse failure instead of an event.
    try std.testing.expect(@hasField(agent.Kind, "unknown"));
    // The three control kinds are serviced inside `next` and never handed
    // out, so a caller switching on `Kind` needs to know they exist.
    try std.testing.expect(@hasField(agent.Kind, "control_request"));
    try std.testing.expect(@hasField(agent.Kind, "sdk_control_request"));
    try std.testing.expect(@hasField(agent.Kind, "control_response"));
    // And the conversation kinds the accessors on `Event` key off.
    try std.testing.expect(@hasField(agent.Kind, "system"));
    try std.testing.expect(@hasField(agent.Kind, "result"));
    try std.testing.expect(@hasField(agent.Kind, "stream_event"));
}

test "the diagnostic accessors return borrowed slices" {
    // Both are documented as views into client-owned memory with a stated
    // lifetime, not copies the caller must free, so their return types have
    // to be plain slices rather than anything error- or allocation-carrying.
    try std.testing.expectEqual([]const u8, returnType(agent.Client.lastLine));
    try std.testing.expectEqual(?[]const u8, returnType(agent.Client.lastControlError));
    try std.testing.expectEqual(?[]const u8, returnType(agent.Client.sessionId));
}
