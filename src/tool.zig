// src/tool.zig
// In-process MCP tools, servers, and permission handlers.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ToolResult = struct {
    text: []const u8,
    /// Reports a recoverable tool failure to Claude.
    is_error: bool = false,
};

/// Runs synchronously in `next`; `arena` resets before each dispatch.
/// Keep results valid through reply writing. May send/interrupt/kill, but never reenter `next`.
pub const ToolHandler = *const fn (
    context: ?*anyopaque,
    arena: Allocator,
    arguments: std.json.Value,
) anyerror!ToolResult;

pub const PermissionDecision = union(enum) {
    /// Keeps the proposed input.
    allow,
    /// Raw replacement JSON object; invalid or oversized replies are denied.
    allow_with_input: []const u8,
    /// Refusal message shown to the model.
    deny: []const u8,
};

/// Handles calls unresolved by tool rules/mode inside `next`, using `ToolHandler` lifetimes.
/// Missing input is JSON null. Errors become named denials; OutOfMemory propagates.
pub const PermissionHandler = *const fn (
    context: ?*anyopaque,
    arena: Allocator,
    tool_name: []const u8,
    input: std.json.Value,
) anyerror!PermissionDecision;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema object for `tools/list`; invalid values fail `open` with `InvalidToolSchema`.
    input_schema: []const u8 = "{\"type\":\"object\",\"properties\":{}}",
    handler: ToolHandler,
    context: ?*anyopaque = null,
};

/// Tools are named `mcp__<server>__<tool>`; allow a server with `mcp__calc__*`.
pub const McpServer = struct {
    name: []const u8,
    /// MCP server version, independent of the package version.
    version: []const u8 = "0.1.0",
    tools: []const Tool = &.{},

    pub fn findTool(server: *const McpServer, name: []const u8) ?*const Tool {
        for (server.tools) |*tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }
};

pub fn findServer(servers: []const McpServer, name: []const u8) ?*const McpServer {
    for (servers) |*server| {
        if (std.mem.eql(u8, server.name, name)) return server;
    }
    return null;
}

// --- tests ---

// `findServer` is internal; public tool tests live in tests/tool_test.zig.
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
