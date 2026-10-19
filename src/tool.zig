// src/tool.zig
// In-process MCP tools, servers, and permission handlers.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ToolResult = struct {
    text: []const u8,
    /// Reports a recoverable tool failure to Claude.
    is_error: bool = false,
};

/// Runs synchronously inside `Client.next`. `arena` resets before each
/// dispatch; returned data must remain valid until the reply is written. May
/// call `send`, `interrupt`, or `kill`; must not call the non-reentrant `next`.
pub const ToolHandler = *const fn (
    context: ?*anyopaque,
    arena: Allocator,
    arguments: std.json.Value,
) anyerror!ToolResult;

/// Permission decision for a tool call.
pub const PermissionDecision = union(enum) {
    /// Run the tool with the input it was proposed with.
    allow,
    /// Replacement input as a raw JSON object. Invalid objects and oversized
    /// reply lines are denied.
    allow_with_input: []const u8,
    /// Refusal message shown to the model; explain how it can proceed.
    deny: []const u8,
};

/// Runs inside `Client.next` for calls not authorized by tool rules or a
/// permission mode, when `Options.permission_handler` is set. Uses the
/// `ToolHandler` arena lifetime. `input` is JSON null when absent. Handler
/// errors become denials containing the error name; OutOfMemory propagates.
pub const PermissionHandler = *const fn (
    context: ?*anyopaque,
    arena: Allocator,
    tool_name: []const u8,
    input: std.json.Value,
) anyerror!PermissionDecision;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema object emitted verbatim in `tools/list`. `Client.open`
    /// rejects malformed JSON and non-object values with
    /// `error.InvalidToolSchema`.
    input_schema: []const u8 = "{\"type\":\"object\",\"properties\":{}}",
    handler: ToolHandler,
    context: ?*anyopaque = null,
};

/// Tools are named `mcp__<server>__<tool>`; allow a server with `mcp__calc__*`.
pub const McpServer = struct {
    name: []const u8,
    /// Server version reported in `initialize`, independent of the package
    /// version.
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

// `findServer` is internal; public `findTool` tests live in
// tests/tool_test.zig.
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
