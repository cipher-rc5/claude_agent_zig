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

/// What a `PermissionHandler` decides about one tool call.
pub const PermissionDecision = union(enum) {
    /// Run the tool with the input it was proposed with.
    allow,
    /// Run the tool with this input instead. A raw JSON object, spliced into
    /// the reply verbatim; it is validated first, and a value that is not a
    /// JSON object becomes a deny rather than a corrupted frame. Bounded like
    /// a tool result: an object too large for one pipe-load is also denied.
    allow_with_input: []const u8,
    /// Refuse the call. The text is shown to the model, so it should say what
    /// to do instead, not just that the call was refused.
    deny: []const u8,
};

/// Invoked on the client's thread when the CLI asks whether Claude may run a
/// tool, which it does only when `Options.permission_handler` is set and the
/// call is not already pre-authorized by `allowed_tools` or a permission mode.
/// `arena` follows the `ToolHandler` contract: reset before each dispatch, so
/// a `deny` or `allow_with_input` string may live in it. `input` is the
/// proposed tool input, or JSON `null` when the request carried none. A
/// handler error becomes a deny carrying the error's name.
pub const PermissionHandler = *const fn (
    context: ?*anyopaque,
    arena: Allocator,
    tool_name: []const u8,
    input: std.json.Value,
) anyerror!PermissionDecision;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// A JSON Schema object, emitted verbatim in the `tools/list` reply. It
    /// is spliced into the protocol frame raw rather than re-encoded, so
    /// `Client.open` checks that it parses as JSON and is an object, and
    /// refuses the session with `error.InvalidToolSchema` otherwise.
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
