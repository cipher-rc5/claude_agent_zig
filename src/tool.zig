// src/tool.zig
// In-process MCP tools: what a handler receives, and how servers group them.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ToolResult = struct {
    text: []const u8,
    /// Reported to Claude as a failed call it can recover from, rather than a
    /// protocol error that stops the run.
    is_error: bool = false,
};

/// Invoked on the client's thread when Claude calls the tool. `arena` is reset
/// immediately before each dispatch, so the handler can allocate freely and
/// whatever it returns stays valid until the reply has been written. Nothing
/// allocated in it survives the next tool call.
pub const ToolHandler = *const fn (
    context: ?*anyopaque,
    arena: Allocator,
    arguments: std.json.Value,
) anyerror!ToolResult;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// A JSON Schema object, emitted verbatim in the `tools/list` reply.
    input_schema: []const u8 = "{\"type\":\"object\",\"properties\":{}}",
    handler: ToolHandler,
    context: ?*anyopaque = null,
};

/// Claude sees these as `mcp__<server name>__<tool name>`, so an allow rule
/// for them looks like `mcp__calc__*`.
pub const McpServer = struct {
    name: []const u8,
    /// Reported to the CLI in the `initialize` handshake as this server's own
    /// version. It matches the package version only by coincidence; the two
    /// are unrelated and version independently.
    version: []const u8 = "0.1.0",
    tools: []const Tool = &.{},

    pub fn findTool(server: *const McpServer, name: []const u8) ?*const Tool {
        for (server.tools) |*tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }
};

/// Locates a server by the name the CLI used in the `mcp_message` envelope.
pub fn findServer(servers: []const McpServer, name: []const u8) ?*const McpServer {
    for (servers) |*server| {
        if (std.mem.eql(u8, server.name, name)) return server;
    }
    return null;
}

// --- tests ---

// Exercises `findServer`, which is `pub` for client.zig but not re-exported by
// agent.zig, so moving this would widen the public surface. The `findTool` half
// of the coverage lives in tests/tool_test.zig, reached through `McpServer`.
test "lookup by name" {
    const tools = [_]Tool{
        .{ .name = "add", .description = "", .handler = undefined },
    };
    const servers = [_]McpServer{.{ .name = "host", .tools = &tools }};

    const server = findServer(&servers, "host").?;
    try std.testing.expectEqualStrings("add", server.findTool("add").?.name);
    try std.testing.expect(server.findTool("missing") == null);
    try std.testing.expect(findServer(&servers, "other") == null);
}
