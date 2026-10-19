// tests/client_test.zig
// Public Client API contracts; private tests stay in src/client.zig.

const std = @import("std");
const agent = @import("agent");

fn returnType(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

test "the write API declares an explicit error set" {
    // Pin explicit signatures so stdlib changes cannot widen public error sets.
    try std.testing.expectEqual(agent.WriteError!void, returnType(agent.Client.send));
    try std.testing.expectEqual(agent.WriteError!void, returnType(agent.Client.sendCommand));
    try std.testing.expectEqual(agent.WriteError!void, returnType(agent.Client.interrupt));

    const closed: agent.WriteError = error.StdinClosed;
    try std.testing.expectEqual(agent.WriteError.StdinClosed, closed);

    const members = [_]agent.WriteError{ error.StdinClosed, error.WriteFailed, error.WriteTimedOut, error.TransportFailed, error.TooManyPendingRequests, error.ReplyTooLong };
    try std.testing.expectEqual(members.len, @typeInfo(agent.WriteError).error_set.error_names.?.len);
}

test "the read and open APIs declare their error sets" {
    try std.testing.expectEqual(agent.OpenError!*agent.Client, returnType(agent.Client.open));
    try std.testing.expectEqual(agent.ReadError!?agent.Event, returnType(agent.Client.next));
    try std.testing.expectEqual(agent.WaitError!agent.Term, returnType(agent.Client.wait));
    try std.testing.expectEqual(agent.Term, returnType(agent.Client.close));

    // Pin ReadError for exhaustive switches; stdlib spawn errors may vary.
    const read_members = [_]agent.ReadError{
        error.ControlRequestRejected,
        error.InvalidJson,
        error.ProtocolTooLong,
        error.ProtocolTooDeep,
        error.StdinClosed,
        error.ReadFailed,
        error.WriteFailed,
        error.OutOfMemory,
        error.InitializationRejected,
        error.WriteTimedOut,
        error.TransportFailed,
        error.ReplyTooLong,
    };
    try std.testing.expectEqual(read_members.len, @typeInfo(agent.ReadError).error_set.error_names.?.len);
    try std.testing.expectEqual(agent.ReadError.ControlRequestRejected, read_members[0]);

    const open_members = [_]agent.OpenError{
        error.InvalidToolSchema,
        error.InvalidMaxLineBytes,
        error.OutOfMemory,
        error.FileNotFound,
    };
    try std.testing.expectEqual(agent.OpenError.InvalidToolSchema, open_members[0]);
}

test "the public surface re-exports every type a caller needs" {
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

    const tool_fn = @typeInfo(agent.ToolHandler).pointer.child;
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(tool_fn).@"fn".param_types.len);
    try std.testing.expectEqual(anyerror!agent.ToolResult, @typeInfo(tool_fn).@"fn".return_type.?);
    const permission_fn = @typeInfo(agent.PermissionHandler).pointer.child;
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(permission_fn).@"fn".param_types.len);
    try std.testing.expectEqual(
        anyerror!agent.PermissionDecision,
        @typeInfo(permission_fn).@"fn".return_type.?,
    );

    try std.testing.expect(agent.Term == std.process.Child.Term);
    try std.testing.expect(agent.WaitError == std.process.Child.WaitError);

    try std.testing.expect(@TypeOf(agent.max_tool_result_bytes) == usize);
    try std.testing.expect(agent.max_tool_result_bytes > 0);
    const version: []const u8 = agent.min_cli_version;
    try std.testing.expect(version.len > 0);
}

test "Kind names every wire type the client dispatches on, plus unknown" {
    try std.testing.expect(@hasField(agent.Kind, "unknown"));
    try std.testing.expect(@hasField(agent.Kind, "control_request"));
    try std.testing.expect(@hasField(agent.Kind, "sdk_control_request"));
    try std.testing.expect(@hasField(agent.Kind, "control_response"));
    try std.testing.expect(@hasField(agent.Kind, "system"));
    try std.testing.expect(@hasField(agent.Kind, "result"));
    try std.testing.expect(@hasField(agent.Kind, "stream_event"));
}

test "the diagnostic accessors return borrowed slices" {
    try std.testing.expectEqual([]const u8, returnType(agent.Client.lastLine));
    try std.testing.expectEqual(?[]const u8, returnType(agent.Client.lastControlError));
    try std.testing.expectEqual(?[]const u8, returnType(agent.Client.sessionId));
}

test "lifecycle and readiness APIs expose synchronized typed status" {
    try std.testing.expectEqual(agent.Status, returnType(agent.Client.status));
    try std.testing.expectEqual(agent.WaitError!agent.Term, returnType(agent.Client.terminate));
    try std.testing.expectEqual(agent.WaitError!agent.Term, returnType(agent.Client.forceKill));
    try std.testing.expectEqual(@as(usize, 16_896), agent.max_reply_line_bytes);
    try std.testing.expect(@hasField(agent.InitializationState, "pending"));
    try std.testing.expect(@hasField(agent.InitializationState, "accepted"));
    try std.testing.expect(@hasField(agent.InitializationState, "rejected"));
}
