// src/protocol.zig
// Serializes stream-json messages to the CLI.

const std = @import("std");
const Io = std.Io;

const McpServer = @import("tool.zig").McpServer;
const ToolResult = @import("tool.zig").ToolResult;

/// Stateless MCP revision: version, identity, and capabilities ride in each request's `_meta`.
pub const modern_protocol_version = "2026-07-28";

// Fallback when initialize omits protocolVersion; otherwise echo the offered version.
pub const default_protocol_version = "2025-11-25";

/// Advertised by `server/discover` and `UnsupportedProtocolVersionError`, newest first.
/// Legacy revisions are served through the `initialize` handshake.
pub const supported_protocol_versions = [_][]const u8{ modern_protocol_version, "2025-11-25", "2025-06-18" };

pub fn isLegacyProtocolVersion(version: []const u8) bool {
    for (supported_protocol_versions[1..]) |legacy| {
        if (std.mem.eql(u8, legacy, version)) return true;
    }
    return false;
}

/// Request `_meta` keys reserved by the 2026-07-28 revision.
pub const meta_keys = struct {
    pub const protocol_version = "io.modelcontextprotocol/protocolVersion";
    pub const client_capabilities = "io.modelcontextprotocol/clientCapabilities";
    pub const server_info = "io.modelcontextprotocol/serverInfo";
};

/// JSON-RPC error codes this server emits.
pub const error_codes = struct {
    pub const method_not_found: i32 = -32601;
    /// Unknown tools and malformed requests, including missing required `_meta`.
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
    pub const unsupported_protocol_version: i32 = -32022;
};

/// Modern results may be cached; tools are host-defined, so never share or reuse them.
pub const list_cache_ttl_ms: u32 = 0;
pub const list_cache_scope = "private";

/// Selects the result shape: legacy replies stay byte-compatible with the handshake era.
pub const Era = union(enum) {
    legacy,
    /// 2026-07-28: `resultType`, plus `serverInfo` in `_meta` when known.
    modern: ?*const McpServer,
};

// Mid-turn messages are treated as guidance.
pub fn writeUserMessage(w: *Io.Writer, text: []const u8) !void {
    try writeUserParts(w, &.{text});
}

pub fn writeCommandMessage(w: *Io.Writer, name: []const u8, arguments: []const u8) !void {
    try writeUserParts(w, if (arguments.len == 0) &.{ "/", name } else &.{ "/", name, " ", arguments });
}

// Escape fragments into one string without a temporary command or JSON tree.
fn writeUserParts(w: *Io.Writer, parts: []const []const u8) !void {
    try w.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"");
    for (parts) |part| try std.json.Stringify.encodeJsonStringChars(part, .{}, w);
    try w.writeAll("\"}]}}");
}

// SDK tools and skills are configured through the control protocol.
pub fn writeInitialize(
    js: *std.json.Stringify,
    request_id: []const u8,
    servers: []const McpServer,
    skills: ?[]const []const u8,
) !void {
    try js.beginObject();
    try js.objectField("type");
    try js.write("control_request");
    try js.objectField("request_id");
    try js.write(request_id);
    try js.objectField("request");
    try js.beginObject();
    try js.objectField("subtype");
    try js.write("initialize");
    if (servers.len > 0) {
        try js.objectField("sdkMcpServers");
        try js.beginArray();
        for (servers) |server| try js.write(server.name);
        try js.endArray();
    }
    // Omitted allows all skills; empty allows none.
    if (skills) |list| {
        try js.objectField("skills");
        try js.beginArray();
        for (list) |name| try js.write(name);
        try js.endArray();
    }
    try js.endObject();
    try js.endObject();
}

pub fn writeInterrupt(js: *std.json.Stringify, request_id: []const u8) !void {
    try js.beginObject();
    try js.objectField("type");
    try js.write("control_request");
    try js.objectField("request_id");
    try js.write(request_id);
    try js.objectField("request");
    try js.beginObject();
    try js.objectField("subtype");
    try js.write("interrupt");
    try js.endObject();
    try js.endObject();
}

// Paired with `endControlResponse`.
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

// The CLI requires `mcp_response` to correlate JSON-RPC replies.
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

// `result_json` is spliced verbatim.
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

pub fn writeMcpResultBody(
    js: *std.json.Stringify,
    request_id: []const u8,
    message_id: ?std.json.Value,
    comptime f: anytype,
    args: anytype,
) !void {
    try beginMcpResponse(js, request_id, message_id);
    try js.objectField("result");
    try @call(.auto, f, .{js} ++ args);
    try endMcpResponse(js);
}

// Compact validated JSON to preserve newline framing.
fn writeCompactJson(w: *Io.Writer, raw: []const u8) Io.Writer.Error!void {
    var quoted = false;
    var escaped = false;
    var start: usize = 0;
    for (raw, 0..) |byte, index| {
        if (quoted) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
        } else if (byte == '"') {
            quoted = true;
        } else if (std.ascii.isWhitespace(byte)) {
            try w.writeAll(raw[start..index]);
            start = index + 1;
        }
    }
    try w.writeAll(raw[start..]);
}

// JSON-RPC errors: -32601 unknown method/server, -32602 invalid params or unknown tool.
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

/// `UnsupportedProtocolVersionError`: lists every version this server can serve.
pub fn writeUnsupportedProtocolVersion(
    js: *std.json.Stringify,
    request_id: []const u8,
    message_id: ?std.json.Value,
    requested: []const u8,
) !void {
    try beginMcpResponse(js, request_id, message_id);
    try js.objectField("error");
    try js.beginObject();
    try js.objectField("code");
    try js.write(error_codes.unsupported_protocol_version);
    try js.objectField("message");
    try js.write("Unsupported protocol version");
    try js.objectField("data");
    try js.beginObject();
    try js.objectField("supported");
    try writeSupportedVersions(js);
    try js.objectField("requested");
    try js.write(requested);
    try js.endObject();
    try js.endObject();
    try endMcpResponse(js);
}

fn writeSupportedVersions(js: *std.json.Stringify) !void {
    try js.beginArray();
    for (supported_protocol_versions) |version| try js.write(version);
    try js.endArray();
}

// Unsupported requests still need a reply to prevent CLI timeouts.
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

pub const PermissionInput = union(enum) {
    value: std.json.Value,
    /// Validated by the client; spliced verbatim.
    raw: []const u8,
};

// The CLI requires `updatedInput`, even when unchanged.
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
            try writeCompactJson(js.writer, r);
            js.endWriteRaw();
        },
    }
    try js.endObject();
    try endControlResponse(js);
}

// Denial text is shown to the model.
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

// Bodies spliced into replies by `writeMcpResult`.
pub const results = struct {
    // Echo the offered version; the CLI rejects mismatches.
    pub fn initialize(
        js: *std.json.Stringify,
        server: *const McpServer,
        offered: []const u8,
    ) !void {
        try js.beginObject();
        try js.objectField("protocolVersion");
        try js.write(offered);
        try js.objectField("capabilities");
        try writeCapabilities(js);
        try js.objectField("serverInfo");
        try writeImplementation(js, server);
        try js.endObject();
    }

    /// `server/discover`; only reachable with modern `_meta`.
    pub fn discover(js: *std.json.Stringify, server: *const McpServer) !void {
        try js.beginObject();
        try writeModernFields(js, .{ .modern = server });
        try js.objectField("supportedVersions");
        try writeSupportedVersions(js);
        try js.objectField("capabilities");
        try writeCapabilities(js);
        try writeCacheFields(js);
        try js.endObject();
    }

    // Compact validated schemas to keep one-line framing.
    pub fn toolsList(js: *std.json.Stringify, server: *const McpServer, era: Era) !void {
        try js.beginObject();
        try writeModernFields(js, era);
        if (era == .modern) try writeCacheFields(js);
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
            try writeCompactJson(js.writer, tool.input_schema);
            js.endWriteRaw();
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }

    pub fn toolCall(js: *std.json.Stringify, call: ToolResult, era: Era) !void {
        try js.beginObject();
        try writeModernFields(js, era);
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

    fn writeCapabilities(js: *std.json.Stringify) !void {
        try js.beginObject();
        try js.objectField("tools");
        try js.beginObject();
        try js.objectField("listChanged");
        try js.write(false);
        try js.endObject();
        try js.endObject();
    }

    fn writeImplementation(js: *std.json.Stringify, server: *const McpServer) !void {
        try js.beginObject();
        try js.objectField("name");
        try js.write(server.name);
        try js.objectField("version");
        try js.write(server.version);
        try js.endObject();
    }

    // Servers implementing 2026-07-28 MUST send `resultType` and SHOULD identify themselves.
    fn writeModernFields(js: *std.json.Stringify, era: Era) !void {
        const identity = switch (era) {
            .legacy => return,
            .modern => |server| server,
        };
        try js.objectField("resultType");
        try js.write("complete");
        if (identity) |server| {
            try js.objectField("_meta");
            try js.beginObject();
            try js.objectField(meta_keys.server_info);
            try writeImplementation(js, server);
            try js.endObject();
        }
    }

    fn writeCacheFields(js: *std.json.Stringify) !void {
        try js.objectField("ttlMs");
        try js.write(list_cache_ttl_ms);
        try js.objectField("cacheScope");
        try js.write(list_cache_scope);
    }
};

// --- tests ---

// Private wire-format helpers require module-local tests.

const Rendered = struct {
    out: Io.Writer.Allocating,

    fn deinit(self: *Rendered) void {
        self.out.deinit();
    }

    fn text(self: *Rendered) []const u8 {
        return self.out.written();
    }
};

/// Renders one protocol line for assertions.
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

fn expectRequestEnvelope(text: []const u8, request_id: []const u8, subtype: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try std.testing.expectEqualStrings("control_request", envelope.get("type").?.string);
    try std.testing.expectEqualStrings(request_id, envelope.get("request_id").?.string);
    const request = envelope.get("request").?.object;
    try std.testing.expectEqualStrings(subtype, request.get("subtype").?.string);
    try std.testing.expect(!request.contains("request_id"));
}

test "initialize request correlation belongs to the top-level envelope" {
    var empty = try render(writeInitialize, .{ "zig_1", &[_]McpServer{}, null });
    defer empty.deinit();
    try expectRequestEnvelope(empty.text(), "zig_1", "initialize");
    const servers = [_]McpServer{.{ .name = "host" }};
    const skills: []const []const u8 = &.{"review"};
    var configured = try render(writeInitialize, .{ "quoted\"id\n", &servers, skills });
    defer configured.deinit();
    try expectRequestEnvelope(configured.text(), "quoted\"id\n", "initialize");
}

test "skills distinguishes unset from empty" {
    var unset = try render(writeInitialize, .{ "zig_1", &[_]McpServer{}, null });
    defer unset.deinit();
    try std.testing.expect(std.mem.indexOf(u8, unset.text(), "\"skills\"") == null);

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
    try expectContains(r.text(), "\"mcp_response\"");
    try expectContains(r.text(), "\"jsonrpc\":\"2.0\"");
    try expectContains(r.text(), "\"id\":7");
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
    try expectRequestEnvelope(r.text(), "zig_6", "interrupt");
}

test "tools/list splices input schemas verbatim" {
    const tools = [_]@import("tool.zig").Tool{.{
        .name = "add",
        .description = "Add two numbers.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"number\"}}}",
        .handler = undefined,
    }};
    const server: McpServer = .{ .name = "host", .tools = &tools };

    var r = try render(results.toolsList, .{ &server, Era.legacy });
    defer r.deinit();
    try expectContains(r.text(), "\"name\":\"add\"");
    try expectContains(r.text(), "\"inputSchema\":{\"type\":\"object\"");
}

test "tool call result reports the error flag" {
    var ok = try render(results.toolCall, .{ ToolResult{ .text = "42" }, Era.legacy });
    defer ok.deinit();
    try expectContains(ok.text(), "\"text\":\"42\"");
    try expectContains(ok.text(), "\"isError\":false");

    var failed = try render(results.toolCall, .{ ToolResult{ .text = "boom", .is_error = true }, Era.legacy });
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

    try expectContains(r.text(), "\"subtype\":\"success\"");
    try expectContains(r.text(), "\"request_id\":\"req_1\"");
    try expectContains(r.text(), "\"behavior\":\"allow\"");
    try expectContains(r.text(), "\"updatedInput\":{\"command\":\"ls -la\",\"timeout\":5}");
    try std.testing.expect(std.mem.indexOf(u8, r.text(), "mcp_response") == null);
}

test "permission allow splices a replacement input raw" {
    var r = try render(writePermissionAllow, .{ "req_2", PermissionInput{ .raw = "{\"command\":\"ls\"}" } });
    defer r.deinit();
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
