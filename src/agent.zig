// src/agent.zig
// Client for the Claude Code CLI stream-json protocol.
//
// The Agent SDK ships only for Python and TypeScript. Both are thin wrappers
// around the `claude` binary running with `--input-format stream-json` and
// `--output-format stream-json`, which is a newline-delimited JSON protocol
// over the child process stdin/stdout pipes. This module speaks that protocol
// directly.
//
// This file is the public surface. The implementation is split by concern:
//
//   options.zig   session configuration, and the CLI flags it becomes
//   event.zig     one protocol line, and the accessors for reading it
//   tool.zig      in-process MCP tools and the servers grouping them
//   protocol.zig  the wire format: every line this process writes
//   client.zig    process lifecycle, the read loop, control dispatch

const options = @import("options.zig");
const event = @import("event.zig");
const tool = @import("tool.zig");
const client = @import("client.zig");

pub const Options = options.Options;
pub const PermissionMode = options.PermissionMode;

pub const Event = event.Event;
pub const Kind = event.Kind;

pub const Tool = tool.Tool;
pub const ToolHandler = tool.ToolHandler;
pub const ToolResult = tool.ToolResult;
pub const McpServer = tool.McpServer;

pub const Client = client.Client;
pub const OpenError = client.OpenError;
pub const ReadError = client.ReadError;
pub const WriteError = client.WriteError;

/// Re-exported from `std.process.Child`: both appear in the signatures of
/// `Client.wait` and `Client.close`, so a caller that names either type would
/// otherwise need its own `@import("std")` purely to spell a return value.
pub const Term = @import("std").process.Child.Term;
pub const WaitError = @import("std").process.Child.WaitError;

/// The ceiling on a tool handler's result text. A handler returning more gets
/// an `is_error` result in its place; see `Client.max_tool_result_bytes` for
/// why the bound exists.
pub const max_tool_result_bytes = client.max_tool_result_bytes;

test {
    @import("std").testing.refAllDecls(@This());
    _ = options;
    _ = event;
    _ = tool;
    _ = @import("protocol.zig");
    _ = client;
}
