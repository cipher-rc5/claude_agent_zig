// src/agent.zig
// Client for the Claude Code CLI stream-json protocol.
//
// The Agent SDK ships only for Python and TypeScript. Both are thin wrappers
// around the `claude` binary running with `--input-format stream-json` and
// `--output-format stream-json`, which is a newline-delimited JSON protocol
// over the child process stdin/stdout pipes. This module speaks that protocol
// directly.

const std = @import("std");
const Io = std.Io;

/// Used only when the CLI's initialize request carries no protocolVersion.
/// Normally the version it offers is echoed back verbatim.
const default_protocol_version = "2025-06-18";
const Allocator = std.mem.Allocator;

pub const PermissionMode = enum {
    manual,
    auto,
    dont_ask,
    accept_edits,
    plan,

    pub fn cliName(mode: PermissionMode) []const u8 {
        return switch (mode) {
            .manual => "manual",
            .auto => "auto",
            .dont_ask => "dontAsk",
            .accept_edits => "acceptEdits",
            .plan => "plan",
        };
    }
};

pub const Options = struct {
    /// Path to the CLI, or a bare name resolved through PATH.
    claude_path: []const u8 = "claude",
    /// Working directory for the agent.
    cwd: std.process.Child.Cwd = .inherit,
    /// Skip auto-discovery of hooks, plugins, MCP servers, auto memory and
    /// CLAUDE.md. Also narrows the built-in tool set to the shell and file
    /// tools, so WebSearch, WebFetch, Agent, Skill and the rest are not
    /// registered. Off by default; turn it on only for locked-down CI runs
    /// that want a fixed tool set, and note it requires ANTHROPIC_API_KEY
    /// rather than subscription auth.
    bare: bool = false,
    /// Emit `stream_event` deltas as tokens are produced.
    include_partial_messages: bool = true,
    model: ?[]const u8 = null,
    /// Permission rule syntax, for example `Read,Edit,Bash(git diff *)`.
    allowed_tools: ?[]const u8 = null,
    permission_mode: ?PermissionMode = null,
    append_system_prompt: ?[]const u8 = null,
    /// Path to an MCP config file, or an inline JSON object.
    mcp_config: ?[]const u8 = null,
    /// Restricts the session's built-in tools to the ones named here, for
    /// example `Read,Edit,Bash,WebSearch`. Leave null to keep the full set.
    /// Skills run through the `Skill` tool, so include it when passing a list.
    tools: ?[]const u8 = null,
    /// Which filesystem settings load, as a comma list of `user`, `project`,
    /// and `local`. This is what governs skill discovery: `user` picks up
    /// `~/.claude/skills/`, `project` picks up `.claude/skills/` in the
    /// working directory and its parents up to the repository root. Leave
    /// null for the CLI default.
    setting_sources: ?[]const u8 = null,
    /// Extra working directories. Each contributes its `.claude/skills/`, but
    /// not its commands or agents.
    add_dirs: []const []const u8 = &.{},
    /// Plugin directories to load for this session. A plugin can carry skills,
    /// subagents, hooks, and MCP servers.
    plugin_dirs: []const []const u8 = &.{},
    /// Subagent definitions as a JSON object.
    agents_json: ?[]const u8 = null,
    /// Turns off every skill and command for the session.
    disable_slash_commands: bool = false,
    /// Ignore every MCP source except `mcp_config`.
    strict_mcp_config: bool = false,
    max_turns: ?u32 = null,
    /// Restricts which discovered skills Claude may invoke, by name. This is
    /// an invocation allowlist, not a discovery filter: `system/init` still
    /// reports every skill it found either way, but a skill outside the list
    /// cannot be called. Note that null and an empty slice differ. Leave it
    /// null to allow every discovered skill; pass an empty slice to allow
    /// none. Sent on the `initialize` control request rather than as a CLI
    /// flag, so it needs no `extra_args`.
    skills: ?[]const []const u8 = null,
    /// In-process MCP servers. Tools live in this process and are reached
    /// over the control protocol, so no subprocess is involved.
    sdk_mcp_servers: []const McpServer = &.{},
    /// Resume an existing session by id.
    resume_session_id: ?[]const u8 = null,
    /// Appended verbatim after the flags this module generates.
    extra_args: []const []const u8 = &.{},

    stdout_buffer_size: usize = 64 * 1024,
    stdin_buffer_size: usize = 16 * 1024,
    /// Refuse to buffer a single protocol line larger than this.
    max_line_bytes: usize = 32 * 1024 * 1024,
};

pub const ToolResult = struct {
    text: []const u8,
    /// Reported to Claude as a failed call it can recover from, rather than a
    /// protocol error that stops the run.
    is_error: bool = false,
};

/// Invoked on the client's thread when Claude calls the tool. `arena` is reset
/// after the result is written, so the handler can allocate freely.
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
    version: []const u8 = "0.1.0",
    tools: []const Tool,
};

pub const Kind = enum {
    /// Session lifecycle: `init`, `api_retry`, `plugin_install`.
    system,
    assistant,
    user,
    /// Terminal message for a turn, carrying cost and session metadata.
    result,
    /// Token-level delta, present only with `include_partial_messages`.
    stream_event,
    control_request,
    sdk_control_request,
    control_response,
    unknown,
};

/// One protocol line. Owns an arena holding the parsed tree.
pub const Event = struct {
    kind: Kind,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(event: *Event) void {
        event.parsed.deinit();
        event.* = undefined;
    }

    pub fn root(event: Event) std.json.Value {
        return event.parsed.value;
    }

    pub fn getString(event: Event, key: []const u8) ?[]const u8 {
        const obj = switch (event.parsed.value) {
            .object => |o| o,
            else => return null,
        };
        return switch (obj.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    /// Array field of the event object, for example `skills`, `tools`, or
    /// `slash_commands` on `system/init`.
    pub fn getArray(event: Event, key: []const u8) ?[]const std.json.Value {
        const obj = switch (event.parsed.value) {
            .object => |o| o,
            else => return null,
        };
        return switch (obj.get(key) orelse return null) {
            .array => |a| a.items,
            else => null,
        };
    }

    /// Whether `key` holds a string array containing `needle`. Use it on
    /// `system/init` to confirm a skill or tool actually loaded before the
    /// session starts working.
    pub fn arrayContains(event: Event, key: []const u8, needle: []const u8) bool {
        const items = event.getArray(key) orelse return false;
        for (items) |item| {
            switch (item) {
                .string => |s| if (std.mem.eql(u8, s, needle)) return true,
                else => {},
            }
        }
        return false;
    }

    pub fn subtype(event: Event) ?[]const u8 {
        return event.getString("subtype");
    }

    pub fn sessionId(event: Event) ?[]const u8 {
        return event.getString("session_id");
    }

    /// Text of a `stream_event` `text_delta`, if this event is one.
    pub fn textDelta(event: Event) ?[]const u8 {
        if (event.kind != .stream_event) return null;
        const obj = switch (event.parsed.value) {
            .object => |o| o,
            else => return null,
        };
        const inner = switch (obj.get("event") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const delta = switch (inner.get("delta") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const delta_type = switch (delta.get("type") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        if (!std.mem.eql(u8, delta_type, "text_delta")) return null;
        return switch (delta.get("text") orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    /// Final text of a `result` event.
    pub fn resultText(event: Event) ?[]const u8 {
        if (event.kind != .result) return null;
        return event.getString("result");
    }
};

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

pub const OpenError = std.process.SpawnError || Allocator.Error || Io.Writer.Error;

pub const ReadError = error{
    ProtocolTooLong,
    ReadFailed,
    WriteFailed,
    InvalidJson,
} || Allocator.Error;

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    argv_arena: std.heap.ArenaAllocator,
    stdin_buffer: []u8,
    stdout_buffer: []u8,
    stdin_writer: Io.File.Writer,
    stdout_reader: Io.File.Reader,
    line: Io.Writer.Allocating,
    max_line_bytes: usize,
    servers: []const McpServer,
    /// Borrowed from `Options`, like `servers`, so the caller keeps it alive.
    skills: ?[]const []const u8,
    scratch: std.heap.ArenaAllocator,
    next_request_id: u32 = 0,
    session_id: ?[]u8 = null,
    stdin_closed: bool = false,

    /// Spawns the CLI. The returned pointer is stable; the reader and writer
    /// interfaces embed pointers into it.
    pub fn open(gpa: Allocator, io: Io, options: Options) OpenError!*Client {
        const client = try gpa.create(Client);
        errdefer gpa.destroy(client);

        var argv_arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer argv_arena.deinit();
        const argv = try buildArgv(argv_arena.allocator(), options);

        const stdin_buffer = try gpa.alloc(u8, options.stdin_buffer_size);
        errdefer gpa.free(stdin_buffer);
        const stdout_buffer = try gpa.alloc(u8, options.stdout_buffer_size);
        errdefer gpa.free(stdout_buffer);

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = options.cwd,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(io);

        client.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .argv_arena = argv_arena,
            .stdin_buffer = stdin_buffer,
            .stdout_buffer = stdout_buffer,
            .stdin_writer = child.stdin.?.writerStreaming(io, stdin_buffer),
            .stdout_reader = child.stdout.?.readerStreaming(io, stdout_buffer),
            .line = .init(gpa),
            .max_line_bytes = options.max_line_bytes,
            .servers = options.sdk_mcp_servers,
            .skills = options.skills,
            .scratch = .init(gpa),
        };

        if (client.servers.len > 0 or client.skills != null) try client.sendInitialize();
        return client;
    }

    pub fn close(client: *Client) std.process.Child.Term {
        client.closeStdin();
        const term = client.child.wait(client.io) catch blk: {
            client.child.kill(client.io);
            break :blk std.process.Child.Term{ .unknown = 0 };
        };
        const gpa = client.gpa;
        if (client.session_id) |id| gpa.free(id);
        client.scratch.deinit();
        client.line.deinit();
        gpa.free(client.stdin_buffer);
        gpa.free(client.stdout_buffer);
        client.argv_arena.deinit();
        gpa.destroy(client);
        return term;
    }

    /// Signals end of input. The CLI finishes the current turn and exits.
    pub fn closeStdin(client: *Client) void {
        if (client.stdin_closed) return;
        client.stdin_closed = true;
        client.stdin_writer.interface.flush() catch {};
        if (client.child.stdin) |file| {
            file.close(client.io);
            client.child.stdin = null;
        }
    }

    /// Queues a user turn. Safe to call while a turn is in flight; the CLI
    /// treats it as mid-turn guidance.
    pub fn send(client: *Client, text: []const u8) !void {
        std.debug.assert(!client.stdin_closed);
        const w = &client.stdin_writer.interface;

        const content = [_]TextBlock{.{ .text = text }};
        const message: UserMessage = .{ .message = .{ .content = &content } };

        try std.json.Stringify.value(message, .{}, w);
        try w.writeByte('\n');
        try w.flush();
    }

    /// Dispatches a skill or command by name, optionally with arguments.
    /// Dispatch works even for skills the session's skill list omits.
    pub fn sendCommand(client: *Client, name: []const u8, arguments: []const u8) !void {
        var buf: Io.Writer.Allocating = .init(client.gpa);
        defer buf.deinit();
        try buf.writer.print("/{s}", .{name});
        if (arguments.len > 0) try buf.writer.print(" {s}", .{arguments});
        try client.send(buf.written());
    }

    /// Reads the next conversation event. Returns null at end of stream. The
    /// caller owns the returned event.
    ///
    /// Control traffic is serviced here rather than surfaced: when the CLI
    /// asks this process to run one of its `sdk_mcp_servers` tools, the call
    /// is dispatched and answered before this returns, so a tool handler runs
    /// on the caller's thread between two conversation events.
    pub fn next(client: *Client) ReadError!?Event {
        while (true) {
            const line = (try client.nextLine()) orelse return null;
            if (line.len == 0) continue;

            const parsed = std.json.parseFromSlice(
                std.json.Value,
                client.gpa,
                line,
                .{ .allocate = .alloc_always },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidJson,
            };

            var event: Event = .{ .kind = .unknown, .parsed = parsed };
            if (event.getString("type")) |t| {
                event.kind = std.meta.stringToEnum(Kind, t) orelse .unknown;
            }
            if (client.session_id == null) {
                if (event.sessionId()) |id| client.session_id = try client.gpa.dupe(u8, id);
            }

            switch (event.kind) {
                .control_request, .sdk_control_request => {
                    defer event.deinit();
                    // An allocation failure inside the handler surfaces as a
                    // writer failure, so both collapse to WriteFailed here.
                    client.serveControlRequest(event.parsed.value) catch return error.WriteFailed;
                },
                // Acknowledgement of a request this client sent. Nothing to
                // hand back to the caller.
                .control_response => event.deinit(),
                else => return event,
            }
        }
    }

    /// Asks the CLI to abandon the turn in progress.
    pub fn interrupt(client: *Client) !void {
        const w = &client.stdin_writer.interface;
        var id_buf: [32]u8 = undefined;
        const request_id = client.nextRequestId(&id_buf);

        var js: std.json.Stringify = .{ .writer = w };
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
        try w.writeByte('\n');
        try w.flush();
    }

    fn nextRequestId(client: *Client, buf: []u8) []const u8 {
        client.next_request_id += 1;
        return std.fmt.bufPrint(buf, "zig_{d}", .{client.next_request_id}) catch unreachable;
    }

    /// Declares this process's in-process MCP servers and, when set, the
    /// skills Claude may invoke. The CLI routes SDK tool calls back over the
    /// control protocol instead of spawning a subprocess.
    fn sendInitialize(client: *Client) !void {
        const w = &client.stdin_writer.interface;
        var id_buf: [32]u8 = undefined;
        const request_id = client.nextRequestId(&id_buf);

        var js: std.json.Stringify = .{ .writer = w };
        try writeInitialize(&js, request_id, client.servers, client.skills);
        try w.writeByte('\n');
        try w.flush();
    }

    fn findServer(client: *Client, name: []const u8) ?*const McpServer {
        for (client.servers) |*server| {
            if (std.mem.eql(u8, server.name, name)) return server;
        }
        return null;
    }

    fn serveControlRequest(client: *Client, root: std.json.Value) !void {
        const request = objectField(root, "request") orelse return;
        // The CLI puts request_id at the top level, beside `request`. Older
        // shapes nested it inside, so accept either.
        const request_id = stringField(root, "request_id") orelse
            stringField(request, "request_id") orelse return;
        const subtype = stringField(request, "subtype") orelse return;

        if (!std.mem.eql(u8, subtype, "mcp_message")) {
            // Anything else, notably permission prompts, is not implemented
            // here. Answer rather than leave the CLI blocked for 60 seconds.
            return client.sendControlError(request_id, "unsupported control request");
        }

        const server_name = stringField(request, "server_name") orelse "";
        const message = objectField(request, "message") orelse
            return client.sendControlError(request_id, "missing mcp message");
        const method = stringField(message, "method") orelse
            return client.sendControlError(request_id, "missing mcp method");
        const message_id = objectField(message, "id");

        const server = client.findServer(server_name) orelse
            return client.sendMcpError(request_id, message_id, -32601, "unknown server");

        _ = client.scratch.reset(.retain_capacity);
        const arena = client.scratch.allocator();

        if (std.mem.eql(u8, method, "initialize")) {
            var out: Io.Writer.Allocating = .init(arena);
            var js: std.json.Stringify = .{ .writer = &out.writer };
            try js.beginObject();
            try js.objectField("protocolVersion");
            // Echo the version the CLI offered. It drops the connection on a
            // mismatch, and the value moves with CLI releases, so mirroring it
            // is what keeps the handshake working across versions.
            const offered = if (objectField(message, "params")) |params|
                stringField(params, "protocolVersion") orelse default_protocol_version
            else
                default_protocol_version;
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
            return client.sendMcpResult(request_id, message_id, out.written());
        }

        if (std.mem.startsWith(u8, method, "notifications/")) {
            // A notification carries no id, but the CLI still awaits an
            // `mcp_response` envelope for the enclosing control request and
            // stalls the handshake without one. It answers these with an
            // empty result under id 0, so match that.
            return client.sendMcpResult(request_id, .{ .integer = 0 }, "{}");
        }

        if (std.mem.eql(u8, method, "tools/list")) {
            var out: Io.Writer.Allocating = .init(arena);
            var js: std.json.Stringify = .{ .writer = &out.writer };
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
            return client.sendMcpResult(request_id, message_id, out.written());
        }

        if (std.mem.eql(u8, method, "tools/call")) {
            const params = objectField(message, "params") orelse
                return client.sendMcpError(request_id, message_id, -32602, "missing params");
            const tool_name = stringField(params, "name") orelse
                return client.sendMcpError(request_id, message_id, -32602, "missing tool name");
            const arguments = objectField(params, "arguments") orelse std.json.Value{ .null = {} };

            const tool = for (server.tools) |*t| {
                if (std.mem.eql(u8, t.name, tool_name)) break t;
            } else return client.sendMcpError(request_id, message_id, -32601, "unknown tool");

            const call = tool.handler(tool.context, arena, arguments) catch |err| ToolResult{
                .text = @errorName(err),
                .is_error = true,
            };

            var out: Io.Writer.Allocating = .init(arena);
            var js: std.json.Stringify = .{ .writer = &out.writer };
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
            return client.sendMcpResult(request_id, message_id, out.written());
        }

        return client.sendMcpError(request_id, message_id, -32601, "unsupported mcp method");
    }

    /// The `mcp_response` wrapper is load-bearing. Without it the CLI does not
    /// match the reply to its request and stalls until its own timeout.
    fn sendMcpResult(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        result_json: []const u8,
    ) !void {
        const w = &client.stdin_writer.interface;
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("type");
        try js.write("control_response");
        try js.objectField("response");
        try js.beginObject();
        try js.objectField("subtype");
        try js.write("success");
        try js.objectField("request_id");
        try js.write(request_id);
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
        try js.objectField("result");
        try js.beginWriteRaw();
        try js.writer.writeAll(result_json);
        js.endWriteRaw();
        try js.endObject();
        try js.endObject();
        try js.endObject();
        try js.endObject();
        try w.writeByte('\n');
        try w.flush();
    }

    fn sendMcpError(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        code: i32,
        message: []const u8,
    ) !void {
        const w = &client.stdin_writer.interface;
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("type");
        try js.write("control_response");
        try js.objectField("response");
        try js.beginObject();
        try js.objectField("subtype");
        try js.write("success");
        try js.objectField("request_id");
        try js.write(request_id);
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
        try js.objectField("error");
        try js.beginObject();
        try js.objectField("code");
        try js.write(code);
        try js.objectField("message");
        try js.write(message);
        try js.endObject();
        try js.endObject();
        try js.endObject();
        try js.endObject();
        try js.endObject();
        try w.writeByte('\n');
        try w.flush();
    }

    fn sendControlSuccessEmpty(client: *Client, request_id: []const u8) !void {
        const w = &client.stdin_writer.interface;
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("type");
        try js.write("control_response");
        try js.objectField("response");
        try js.beginObject();
        try js.objectField("subtype");
        try js.write("success");
        try js.objectField("request_id");
        try js.write(request_id);
        try js.endObject();
        try js.endObject();
        try w.writeByte('\n');
        try w.flush();
    }

    fn sendControlError(client: *Client, request_id: []const u8, message: []const u8) !void {
        const w = &client.stdin_writer.interface;
        var js: std.json.Stringify = .{ .writer = w };
        try js.beginObject();
        try js.objectField("type");
        try js.write("control_response");
        try js.objectField("response");
        try js.beginObject();
        try js.objectField("subtype");
        try js.write("error");
        try js.objectField("request_id");
        try js.write(request_id);
        try js.objectField("error");
        try js.write(message);
        try js.endObject();
        try js.endObject();
        try w.writeByte('\n');
        try w.flush();
    }

    /// The raw line, valid until the next call.
    fn nextLine(client: *Client) ReadError!?[]const u8 {
        client.line.clearRetainingCapacity();
        const r = &client.stdout_reader.interface;
        _ = r.streamDelimiterLimit(
            &client.line.writer,
            '\n',
            .limited(client.max_line_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.ProtocolTooLong,
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };

        // streamDelimiterLimit leaves the delimiter buffered. An empty buffer
        // instead means the stream ended.
        if (r.bufferedLen() == 0) {
            const written = client.line.written();
            return if (written.len == 0) null else written;
        }
        r.toss(1);
        return client.line.written();
    }
};

fn objectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    return obj.get(key);
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (objectField(value, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn buildArgv(arena: Allocator, options: Options) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;

    try argv.append(arena, options.claude_path);
    try argv.appendSlice(arena, &.{
        "--print",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
    });
    if (options.bare) try argv.append(arena, "--bare");
    if (options.include_partial_messages) try argv.append(arena, "--include-partial-messages");
    if (options.model) |v| try argv.appendSlice(arena, &.{ "--model", v });
    if (options.allowed_tools) |v| try argv.appendSlice(arena, &.{ "--allowedTools", v });
    if (options.permission_mode) |v| {
        try argv.appendSlice(arena, &.{ "--permission-mode", v.cliName() });
    }
    if (options.append_system_prompt) |v| {
        try argv.appendSlice(arena, &.{ "--append-system-prompt", v });
    }
    if (options.tools) |v| try argv.appendSlice(arena, &.{ "--tools", v });
    if (options.setting_sources) |v| try argv.appendSlice(arena, &.{ "--setting-sources", v });
    for (options.add_dirs) |v| try argv.appendSlice(arena, &.{ "--add-dir", v });
    for (options.plugin_dirs) |v| try argv.appendSlice(arena, &.{ "--plugin-dir", v });
    if (options.agents_json) |v| try argv.appendSlice(arena, &.{ "--agents", v });
    if (options.disable_slash_commands) try argv.append(arena, "--disable-slash-commands");
    if (options.strict_mcp_config) try argv.append(arena, "--strict-mcp-config");
    if (options.max_turns) |v| {
        try argv.appendSlice(arena, &.{ "--max-turns", try std.fmt.allocPrint(arena, "{d}", .{v}) });
    }
    if (options.mcp_config) |v| try argv.appendSlice(arena, &.{ "--mcp-config", v });
    if (options.resume_session_id) |v| try argv.appendSlice(arena, &.{ "--resume", v });
    try argv.appendSlice(arena, options.extra_args);

    return argv.toOwnedSlice(arena);
}

/// Serializes the `initialize` control request. Split out from the writer so
/// the field shapes the CLI is strict about stay testable without a subprocess.
fn writeInitialize(
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

test "argv carries the streaming protocol flags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv(arena.allocator(), .{
        .allowed_tools = "Read,Edit",
        .permission_mode = .accept_edits,
    });

    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expect(containsPair(argv, "--input-format", "stream-json"));
    try std.testing.expect(containsPair(argv, "--output-format", "stream-json"));
    try std.testing.expect(containsPair(argv, "--allowedTools", "Read,Edit"));
    try std.testing.expect(containsPair(argv, "--permission-mode", "acceptEdits"));
}

fn containsPair(argv: []const []const u8, flag: []const u8, value: []const u8) bool {
    for (argv, 0..) |arg, i| {
        if (!std.mem.eql(u8, arg, flag)) continue;
        if (i + 1 < argv.len and std.mem.eql(u8, argv[i + 1], value)) return true;
    }
    return false;
}

test "argv carries skill discovery flags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv(arena.allocator(), .{
        .setting_sources = "user,project",
        .add_dirs = &.{ "../shared", "../design" },
        .plugin_dirs = &.{"/opt/plugins/review"},
        .tools = "Skill,Read,Bash",
        .max_turns = 12,
    });

    try std.testing.expect(containsPair(argv, "--setting-sources", "user,project"));
    try std.testing.expect(containsPair(argv, "--add-dir", "../shared"));
    try std.testing.expect(containsPair(argv, "--add-dir", "../design"));
    try std.testing.expect(containsPair(argv, "--plugin-dir", "/opt/plugins/review"));
    try std.testing.expect(containsPair(argv, "--tools", "Skill,Read,Bash"));
    try std.testing.expect(containsPair(argv, "--max-turns", "12"));
    // --bare would defeat all of the above.
    for (argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--bare"));
}

test "init event reports loaded skills" {
    const line =
        \\{"type":"system","subtype":"init","session_id":"s1","skills":["code-review","security-check"],"slash_commands":["compact","security-check"]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    var event: Event = .{ .kind = .system, .parsed = parsed };
    defer event.deinit();

    try std.testing.expect(event.arrayContains("skills", "security-check"));
    try std.testing.expect(!event.arrayContains("skills", "deploy"));
    try std.testing.expectEqual(@as(usize, 2), event.getArray("slash_commands").?.len);
}

test "text delta extraction" {
    const line =
        \\{"type":"stream_event","session_id":"abc","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    var event: Event = .{ .kind = .stream_event, .parsed = parsed };
    defer event.deinit();

    try std.testing.expectEqualStrings("hello", event.textDelta().?);
    try std.testing.expectEqualStrings("abc", event.sessionId().?);
}

fn initializeJson(arena: std.mem.Allocator, options: Options) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try writeInitialize(&js, "zig_1", options.sdk_mcp_servers, options.skills);
    return out.written();
}

test "skills distinguishes unset from empty" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Unset allows every discovered skill, and the CLI signals that by the
    // field being absent rather than by an empty array.
    const unset = try initializeJson(a, .{});
    try std.testing.expect(std.mem.indexOf(u8, unset, "\"skills\"") == null);

    // Empty is a real value meaning "allow none".
    const empty = try initializeJson(a, .{ .skills = &.{} });
    try std.testing.expect(std.mem.indexOf(u8, empty, "\"skills\":[]") != null);

    const listed = try initializeJson(a, .{ .skills = &.{ "cc-audit", "code-review" } });
    try std.testing.expect(
        std.mem.indexOf(u8, listed, "\"skills\":[\"cc-audit\",\"code-review\"]") != null,
    );
}

test "initialize omits sdkMcpServers when there are none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const skills_only = try initializeJson(a, .{ .skills = &.{"cc-audit"} });
    try std.testing.expect(std.mem.indexOf(u8, skills_only, "sdkMcpServers") == null);

    // The CLI is strict about both names, so pin the exact camelCase spelling.
    const servers = [_]McpServer{.{ .name = "host", .tools = &.{} }};
    const with_servers = try initializeJson(a, .{ .sdk_mcp_servers = &servers });
    try std.testing.expect(
        std.mem.indexOf(u8, with_servers, "\"sdkMcpServers\":[\"host\"]") != null,
    );
}
