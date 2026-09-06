// src/protocol.zig
// The stream-json wire format: every line this process writes to the CLI.
//
// These are free functions over a writer rather than methods on the client, so
// the field shapes the CLI is strict about stay testable without a subprocess.

const std = @import("std");
const Io = std.Io;

const McpServer = @import("tool.zig").McpServer;
const ToolResult = @import("tool.zig").ToolResult;

/// Used only when the CLI's initialize request carries no protocolVersion.
/// Normally the version it offers is echoed back verbatim.
pub const default_protocol_version = "2025-06-18";

/// Wire shape of a user turn on stdin.
const TextBlock = struct {
    type: []const u8 = "text",
    text: []const u8,
};

const UserMessage = struct {
    type: []const u8 = "user",
    message: struct {
        role: []const u8 = "user",
        content: []const TextBlock,
    },
};

/// A user turn. The CLI treats one sent mid-turn as guidance.
pub fn writeUserMessage(w: *Io.Writer, text: []const u8) !void {
    const content = [_]TextBlock{.{ .text = text }};
    const message: UserMessage = .{ .message = .{ .content = &content } };
    try std.json.Stringify.value(message, .{}, w);
}

/// Declares this process's in-process MCP servers and, when set, the skills
/// Claude may invoke. The CLI routes SDK tool calls back over the control
/// protocol instead of spawning a subprocess.
pub fn writeInitialize(
    js: *std.json.Stringify,
    request_id: []const u8,
    servers: []const McpServer,
    skills: ?[]const []const u8,
) !void {
    try js.beginObject();
    try js.objectField("type");
    try js.write("control_request");
    try js.objectField("request");
    try js.beginObject();
    try js.objectField("subtype");
    try js.write("initialize");
    try js.objectField("request_id");
    try js.write(request_id);
    if (servers.len > 0) {
        try js.objectField("sdkMcpServers");
        try js.beginArray();
        for (servers) |server| try js.write(server.name);
        try js.endArray();
    }
    // Omitting the field entirely is what allows every skill. An empty array
    // is a real value meaning "allow none", so this cannot collapse to a
    // length check.
    if (skills) |list| {
        try js.objectField("skills");
        try js.beginArray();
        for (list) |name| try js.write(name);
        try js.endArray();
    }
    try js.endObject();
    try js.endObject();
}

/// Asks the CLI to abandon the turn in progress.
pub fn writeInterrupt(js: *std.json.Stringify, request_id: []const u8) !void {
    try js.beginObject();
    try js.objectField("type");
    try js.write("control_request");
    try js.objectField("request");
    try js.beginObject();
    try js.objectField("subtype");
    try js.write("interrupt");
    try js.objectField("request_id");
    try js.write(request_id);
    try js.endObject();
    try js.endObject();
}

/// Opens `{"type":"control_response","response":{"subtype":...,"request_id":...`
/// and leaves the two objects open for the caller to add fields and close with
/// `endControlResponse`.
fn beginControlResponse(
    js: *std.json.Stringify,
    subtype: []const u8,
    request_id: []const u8,
) !void {
    try js.beginObject();
    try js.objectField("type");
    try js.write("control_response");
    try js.objectField("response");
    try js.beginObject();
    try js.objectField("subtype");
    try js.write(subtype);
    try js.objectField("request_id");
    try js.write(request_id);
}

fn endControlResponse(js: *std.json.Stringify) !void {
    try js.endObject();
    try js.endObject();
}

/// The `mcp_response` wrapper is load-bearing. Without it the CLI does not
/// match the reply to its request and stalls until its own timeout. Leaves the
/// jsonrpc object open for either a `result` or an `error` field.
fn beginMcpResponse(
    js: *std.json.Stringify,
    request_id: []const u8,
    message_id: ?std.json.Value,
) !void {
    try beginControlResponse(js, "success", request_id);
    try js.objectField("response");
    try js.beginObject();
    try js.objectField("mcp_response");
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    if (message_id) |id| {
        try js.objectField("id");
        try js.write(id);
    }
}

fn endMcpResponse(js: *std.json.Stringify) !void {
    try js.endObject();
    try js.endObject();
    try endControlResponse(js);
}

/// A successful MCP reply. `result_json` is spliced in verbatim.
pub fn writeMcpResult(
    js: *std.json.Stringify,
    request_id: []const u8,
    message_id: ?std.json.Value,
    result_json: []const u8,
) !void {
    try beginMcpResponse(js, request_id, message_id);
    try js.objectField("result");
    try js.beginWriteRaw();
    try js.writer.writeAll(result_json);
    js.endWriteRaw();
    try endMcpResponse(js);
}

/// A JSON-RPC error reply. Codes follow the spec: -32601 unknown method or
/// server, -32602 bad params.
pub fn writeMcpError(
    js: *std.json.Stringify,
    request_id: []const u8,
    message_id: ?std.json.Value,
    code: i32,
    message: []const u8,
) !void {
    try beginMcpResponse(js, request_id, message_id);
    try js.objectField("error");
    try js.beginObject();
    try js.objectField("code");
    try js.write(code);
    try js.objectField("message");
    try js.write(message);
    try js.endObject();
    try endMcpResponse(js);
}

/// Answers a control request this client does not implement. Answering at all
/// is the point: silence leaves the CLI blocked until its own timeout.
pub fn writeControlError(
    js: *std.json.Stringify,
    request_id: []const u8,
    message: []const u8,
) !void {
    try beginControlResponse(js, "error", request_id);
    try js.objectField("error");
    try js.write(message);
    try endControlResponse(js);
}

/// The input a permission reply carries back: the tool input as it was
/// proposed, or a replacement the handler already rendered as JSON.
pub const PermissionInput = union(enum) {
    value: std.json.Value,
    /// Spliced in verbatim. The client validates it before it gets here.
    raw: []const u8,
};

/// Allows a `can_use_tool` request. The `behavior`/`updatedInput` shape is
/// the one the official SDKs answer with; the CLI reads `updatedInput` as
/// the input to run the tool with, so it is always sent, even when unchanged.
pub fn writePermissionAllow(
    js: *std.json.Stringify,
    request_id: []const u8,
    input: PermissionInput,
) !void {
    try beginControlResponse(js, "success", request_id);
    try js.objectField("response");
    try js.beginObject();
    try js.objectField("behavior");
    try js.write("allow");
    try js.objectField("updatedInput");
    switch (input) {
        .value => |v| try js.write(v),
        .raw => |r| {
            try js.beginWriteRaw();
            try js.writer.writeAll(r);
            js.endWriteRaw();
        },
    }
    try js.endObject();
    try endControlResponse(js);
}

/// Denies a `can_use_tool` request. `message` is what the model sees.
pub fn writePermissionDeny(
    js: *std.json.Stringify,
    request_id: []const u8,
    message: []const u8,
) !void {
    try beginControlResponse(js, "success", request_id);
    try js.objectField("response");
    try js.beginObject();
    try js.objectField("behavior");
    try js.write("deny");
    try js.objectField("message");
    try js.write(message);
    try js.endObject();
    try endControlResponse(js);
}

/// Bodies of the MCP replies this client serves, as the `result` payload that
/// `writeMcpResult` splices in.
pub const results = struct {
    /// `initialize`. `offered` is the protocolVersion the CLI proposed; it
    /// drops the connection on a mismatch, and the value moves with CLI
    /// releases, so mirroring it is what keeps the handshake working.
    pub fn initialize(
        js: *std.json.Stringify,
        server: *const McpServer,
        offered: []const u8,
    ) !void {
        try js.beginObject();
        try js.objectField("protocolVersion");
        try js.write(offered);
        try js.objectField("capabilities");
        try js.beginObject();
        try js.objectField("tools");
        try js.beginObject();
        try js.objectField("listChanged");
        try js.write(false);
        try js.endObject();
        try js.endObject();
        try js.objectField("serverInfo");
        try js.beginObject();
        try js.objectField("name");
        try js.write(server.name);
        try js.objectField("version");
        try js.write(server.version);
        try js.endObject();
        try js.endObject();
    }

    /// `tools/list`. Each `input_schema` is spliced in verbatim.
    pub fn toolsList(js: *std.json.Stringify, server: *const McpServer) !void {
        try js.beginObject();
        try js.objectField("tools");
        try js.beginArray();
        for (server.tools) |tool| {
            try js.beginObject();
            try js.objectField("name");
            try js.write(tool.name);
            try js.objectField("description");
            try js.write(tool.description);
            try js.objectField("inputSchema");
            try js.beginWriteRaw();
            try js.writer.writeAll(tool.input_schema);
            js.endWriteRaw();
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }

    /// `tools/call`.
    pub fn toolCall(js: *std.json.Stringify, call: ToolResult) !void {
        try js.beginObject();
        try js.objectField("content");
        try js.beginArray();
        try js.beginObject();
        try js.objectField("type");
        try js.write("text");
        try js.objectField("text");
        try js.write(call.text);
        try js.endObject();
        try js.endArray();
        try js.objectField("isError");
        try js.write(call.is_error);
        try js.endObject();
    }
};

// --- tests ---

// The functions under test are `pub` for client.zig, but agent.zig
// deliberately does not re-export the wire format. A tests/ file could reach
// them only by widening the public surface, or by making protocol.zig its own
// module — which Zig forbids while agent.zig also imports it, since a file
// belongs to exactly one module. `render` and `expectContains` stay private
// for the same reason.

const Rendered = struct {
    out: Io.Writer.Allocating,

    fn deinit(self: *Rendered) void {
        self.out.deinit();
    }

    fn text(self: *Rendered) []const u8 {
        return self.out.written();
    }
};

/// Renders one line through a fresh Stringify, so tests read as a single call.
fn render(comptime f: anytype, args: anytype) !Rendered {
    var result: Rendered = .{ .out = .init(std.testing.allocator) };
    errdefer result.deinit();
    var js: std.json.Stringify = .{ .writer = &result.out.writer };
    try @call(.auto, f, .{&js} ++ args);
    return result;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n  {s}\nin:\n  {s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "skills distinguishes unset from empty" {
    // Unset allows every discovered skill, and the CLI signals that by the
    // field being absent rather than by an empty array.
    var unset = try render(writeInitialize, .{ "zig_1", &[_]McpServer{}, null });
    defer unset.deinit();
    try std.testing.expect(std.mem.indexOf(u8, unset.text(), "\"skills\"") == null);

    // Empty is a real value meaning "allow none".
    const none: []const []const u8 = &.{};
    var empty = try render(writeInitialize, .{ "zig_1", &[_]McpServer{}, none });
    defer empty.deinit();
    try expectContains(empty.text(), "\"skills\":[]");

    const two: []const []const u8 = &.{ "cc-audit", "code-review" };
    var listed = try render(writeInitialize, .{ "zig_1", &[_]McpServer{}, two });
    defer listed.deinit();
    try expectContains(listed.text(), "\"skills\":[\"cc-audit\",\"code-review\"]");
}

test "initialize omits sdkMcpServers when there are none" {
    const one: []const []const u8 = &.{"cc-audit"};
    var skills_only = try render(writeInitialize, .{ "zig_1", &[_]McpServer{}, one });
    defer skills_only.deinit();
    try std.testing.expect(std.mem.indexOf(u8, skills_only.text(), "sdkMcpServers") == null);

    // The CLI is strict about both names, so pin the exact camelCase spelling.
    const servers = [_]McpServer{.{ .name = "host" }};
    var with_servers = try render(writeInitialize, .{ "zig_1", &servers, null });
    defer with_servers.deinit();
    try expectContains(with_servers.text(), "\"sdkMcpServers\":[\"host\"]");
}

test "mcp result carries the load-bearing envelope" {
    var r = try render(writeMcpResult, .{ "zig_2", std.json.Value{ .integer = 7 }, "{\"ok\":true}" });
    defer r.deinit();

    try expectContains(r.text(), "\"type\":\"control_response\"");
    try expectContains(r.text(), "\"subtype\":\"success\"");
    try expectContains(r.text(), "\"request_id\":\"zig_2\"");
    // Without the mcp_response wrapper the CLI stalls until its own timeout.
    try expectContains(r.text(), "\"mcp_response\"");
    try expectContains(r.text(), "\"jsonrpc\":\"2.0\"");
    try expectContains(r.text(), "\"id\":7");
    // The raw payload is spliced in, not re-encoded as a string.
    try expectContains(r.text(), "\"result\":{\"ok\":true}");
}

test "mcp reply omits id when the request had none" {
    var r = try render(writeMcpResult, .{ "zig_3", @as(?std.json.Value, null), "{}" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.text(), "\"id\"") == null);
}

test "mcp error carries the jsonrpc code" {
    var r = try render(writeMcpError, .{ "zig_4", @as(?std.json.Value, null), @as(i32, -32601), "unknown tool" });
    defer r.deinit();

    try expectContains(r.text(), "\"subtype\":\"success\"");
    try expectContains(r.text(), "\"error\":{\"code\":-32601,\"message\":\"unknown tool\"}");
}

test "control error is an error subtype, not an mcp reply" {
    var r = try render(writeControlError, .{ "zig_5", "unsupported control request" });
    defer r.deinit();

    try expectContains(r.text(), "\"subtype\":\"error\"");
    try expectContains(r.text(), "\"error\":\"unsupported control request\"");
    try std.testing.expect(std.mem.indexOf(u8, r.text(), "mcp_response") == null);
}

test "interrupt request shape" {
    var r = try render(writeInterrupt, .{"zig_6"});
    defer r.deinit();
    try expectContains(r.text(), "\"type\":\"control_request\"");
    try expectContains(r.text(), "\"subtype\":\"interrupt\"");
}

test "tools/list splices input schemas verbatim" {
    const tools = [_]@import("tool.zig").Tool{.{
        .name = "add",
        .description = "Add two numbers.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"number\"}}}",
        .handler = undefined,
    }};
    const server: McpServer = .{ .name = "host", .tools = &tools };

    var r = try render(results.toolsList, .{&server});
    defer r.deinit();
    try expectContains(r.text(), "\"name\":\"add\"");
    // Spliced raw: a re-encoded schema would arrive escaped as a string.
    try expectContains(r.text(), "\"inputSchema\":{\"type\":\"object\"");
}

test "tool call result reports the error flag" {
    var ok = try render(results.toolCall, .{ToolResult{ .text = "42" }});
    defer ok.deinit();
    try expectContains(ok.text(), "\"text\":\"42\"");
    try expectContains(ok.text(), "\"isError\":false");

    var failed = try render(results.toolCall, .{ToolResult{ .text = "boom", .is_error = true }});
    defer failed.deinit();
    try expectContains(failed.text(), "\"isError\":true");
}

test "initialize result echoes the offered protocol version" {
    const server: McpServer = .{ .name = "host", .version = "9.9.9" };
    var r = try render(results.initialize, .{ &server, "2030-01-01" });
    defer r.deinit();

    try expectContains(r.text(), "\"protocolVersion\":\"2030-01-01\"");
    try expectContains(r.text(), "\"name\":\"host\"");
    try expectContains(r.text(), "\"version\":\"9.9.9\"");
}

test "permission allow echoes the proposed input under updatedInput" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"command":"ls -la","timeout":5}
    , .{});
    defer parsed.deinit();

    var r = try render(writePermissionAllow, .{ "req_1", PermissionInput{ .value = parsed.value } });
    defer r.deinit();

    // A success envelope, not an mcp reply: the CLI matches permission answers
    // by request id alone.
    try expectContains(r.text(), "\"subtype\":\"success\"");
    try expectContains(r.text(), "\"request_id\":\"req_1\"");
    try expectContains(r.text(), "\"behavior\":\"allow\"");
    try expectContains(r.text(), "\"updatedInput\":{\"command\":\"ls -la\",\"timeout\":5}");
    try std.testing.expect(std.mem.indexOf(u8, r.text(), "mcp_response") == null);
}

test "permission allow splices a replacement input raw" {
    var r = try render(writePermissionAllow, .{ "req_2", PermissionInput{ .raw = "{\"command\":\"ls\"}" } });
    defer r.deinit();
    // Raw, not re-encoded as a string.
    try expectContains(r.text(), "\"updatedInput\":{\"command\":\"ls\"}");
}

test "permission deny carries the message the model sees" {
    var r = try render(writePermissionDeny, .{ "req_3", "not on this host" });
    defer r.deinit();
    try expectContains(r.text(), "\"subtype\":\"success\"");
    try expectContains(r.text(), "\"behavior\":\"deny\"");
    try expectContains(r.text(), "\"message\":\"not on this host\"");
    try std.testing.expect(std.mem.indexOf(u8, r.text(), "updatedInput") == null);
}

test "user message wire shape" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeUserMessage(&out.writer, "hello");

    try expectContains(out.written(), "\"type\":\"user\"");
    try expectContains(out.written(), "\"role\":\"user\"");
    try expectContains(out.written(), "\"text\":\"hello\"");
}
