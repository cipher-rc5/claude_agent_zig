// src/agent.zig
// Public API for the Claude Code CLI stream-json client.

const options = @import("options.zig");
const event = @import("event.zig");
const tool = @import("tool.zig");
const client = @import("client.zig");

pub const Options = options.Options;
pub const PermissionMode = options.PermissionMode;
/// Oldest tested CLI version; checked by `just canary`, not `open`.
pub const min_cli_version = options.min_cli_version;

pub const Event = event.Event;
pub const Kind = event.Kind;

pub const Tool = tool.Tool;
pub const ToolHandler = tool.ToolHandler;
pub const ToolResult = tool.ToolResult;
pub const McpServer = tool.McpServer;
pub const PermissionHandler = tool.PermissionHandler;
pub const PermissionDecision = tool.PermissionDecision;

pub const Client = client.Client;
pub const OpenError = client.OpenError;
pub const ReadError = client.ReadError;
pub const WriteError = client.WriteError;
pub const Status = client.Status;
pub const InitializationState = client.InitializationState;
pub const max_reply_line_bytes = client.max_reply_line_bytes;

/// Child exit status and wait error types used by `Client.wait` and
/// `Client.close`.
pub const Term = @import("std").process.Child.Term;
pub const WaitError = @import("std").process.Child.WaitError;

/// Maximum tool result text size. Larger results become `is_error` replies.
pub const max_tool_result_bytes = client.max_tool_result_bytes;

test {
    @import("std").testing.refAllDecls(@This());
    _ = options;
    _ = event;
    _ = tool;
    _ = @import("protocol.zig");
    _ = @import("transport.zig");
    _ = client;
}
