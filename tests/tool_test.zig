// tests/tool_test.zig
// Public tool API tests; internal findServer tests stay in src/tool.zig.

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
