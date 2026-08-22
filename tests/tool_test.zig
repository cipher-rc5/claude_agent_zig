// tests/tool_test.zig
// Black-box tests for the in-process tool types on the public surface.
//
// The `findServer` test stays in src/tool.zig: `findServer` is `pub` so
// client.zig can call it, but agent.zig does not re-export it, so it is not
// public API.

const std = @import("std");
const agent = @import("agent");

test "a server finds its own tools by name" {
    const tools = [_]agent.Tool{
        .{ .name = "add", .description = "", .handler = undefined },
    };
    const server: agent.McpServer = .{ .name = "host", .tools = &tools };

    try std.testing.expectEqualStrings("add", server.findTool("add").?.name);
    try std.testing.expect(server.findTool("missing") == null);
}

test "a tool carries a default object schema and a default server version" {
    // Both defaults are wire-visible: the schema is spliced into `tools/list`
    // verbatim, and the version is reported in the `initialize` handshake.
    const tool: agent.Tool = .{ .name = "noop", .description = "", .handler = undefined };
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{}}",
        tool.input_schema,
    );

    const server: agent.McpServer = .{ .name = "host" };
    try std.testing.expectEqualStrings("0.1.0", server.version);
    try std.testing.expectEqual(@as(usize, 0), server.tools.len);
}

test "a tool result defaults to success" {
    const ok: agent.ToolResult = .{ .text = "42" };
    try std.testing.expect(!ok.is_error);
    const failed: agent.ToolResult = .{ .text = "boom", .is_error = true };
    try std.testing.expect(failed.is_error);
}
