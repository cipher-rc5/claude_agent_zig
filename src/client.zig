// src/client.zig
// Process lifecycle and the read loop: spawns the CLI, pumps protocol lines,
// and services the control traffic that in-process tools arrive on.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const event_mod = @import("event.zig");
const options_mod = @import("options.zig");
const protocol = @import("protocol.zig");
const tool_mod = @import("tool.zig");

const Event = event_mod.Event;
const Kind = event_mod.Kind;
const objectField = event_mod.objectField;
const stringField = event_mod.stringField;
const Options = options_mod.Options;
const McpServer = tool_mod.McpServer;
const ToolResult = tool_mod.ToolResult;

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
        const argv = try options_mod.buildArgv(argv_arena.allocator(), options);

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

        if (options.needsInitialize()) try client.sendInitialize();
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
        try protocol.writeUserMessage(w, text);
        try finishLine(w);
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

    /// Asks the CLI to abandon the turn in progress.
    pub fn interrupt(client: *Client) !void {
        var id_buf: [32]u8 = undefined;
        const request_id = client.nextRequestId(&id_buf);
        try client.writeLine(protocol.writeInterrupt, .{request_id});
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

    // --- writing ---

    fn nextRequestId(client: *Client, buf: []u8) []const u8 {
        client.next_request_id += 1;
        return std.fmt.bufPrint(buf, "zig_{d}", .{client.next_request_id}) catch unreachable;
    }

    /// Terminates and flushes one protocol line. The format is newline
    /// delimited, and the CLI acts on a line only once it lands.
    fn finishLine(w: *Io.Writer) !void {
        try w.writeByte('\n');
        try w.flush();
    }

    /// Writes one line by handing a `Stringify` over stdin to `f`.
    fn writeLine(client: *Client, comptime f: anytype, args: anytype) !void {
        const w = &client.stdin_writer.interface;
        var js: std.json.Stringify = .{ .writer = w };
        try @call(.auto, f, .{&js} ++ args);
        try finishLine(w);
    }

    fn sendInitialize(client: *Client) !void {
        var id_buf: [32]u8 = undefined;
        const request_id = client.nextRequestId(&id_buf);
        try client.writeLine(protocol.writeInitialize, .{ request_id, client.servers, client.skills });
    }

    fn sendMcpResult(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        result_json: []const u8,
    ) !void {
        try client.writeLine(protocol.writeMcpResult, .{ request_id, message_id, result_json });
    }

    fn sendMcpError(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        code: i32,
        message: []const u8,
    ) !void {
        try client.writeLine(protocol.writeMcpError, .{ request_id, message_id, code, message });
    }

    fn sendControlError(client: *Client, request_id: []const u8, message: []const u8) !void {
        try client.writeLine(protocol.writeControlError, .{ request_id, message });
    }

    /// Renders one of `protocol.results` into the scratch arena and sends it
    /// as the payload of an MCP success reply.
    fn sendMcpResultBody(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        comptime f: anytype,
        args: anytype,
    ) !void {
        var out: Io.Writer.Allocating = .init(client.scratch.allocator());
        var js: std.json.Stringify = .{ .writer = &out.writer };
        try @call(.auto, f, .{&js} ++ args);
        try client.sendMcpResult(request_id, message_id, out.written());
    }

    // --- control dispatch ---

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

        const server = tool_mod.findServer(client.servers, server_name) orelse
            return client.sendMcpError(request_id, message_id, -32601, "unknown server");

        _ = client.scratch.reset(.retain_capacity);

        if (std.mem.eql(u8, method, "initialize")) {
            const offered = if (objectField(message, "params")) |params|
                stringField(params, "protocolVersion") orelse protocol.default_protocol_version
            else
                protocol.default_protocol_version;
            return client.sendMcpResultBody(
                request_id,
                message_id,
                protocol.results.initialize,
                .{ server, offered },
            );
        }

        if (std.mem.startsWith(u8, method, "notifications/")) {
            // A notification carries no id, but the CLI still awaits an
            // `mcp_response` envelope for the enclosing control request and
            // stalls the handshake without one. It answers these with an
            // empty result under id 0, so match that.
            return client.sendMcpResult(request_id, .{ .integer = 0 }, "{}");
        }

        if (std.mem.eql(u8, method, "tools/list")) {
            return client.sendMcpResultBody(
                request_id,
                message_id,
                protocol.results.toolsList,
                .{server},
            );
        }

        if (std.mem.eql(u8, method, "tools/call")) {
            const params = objectField(message, "params") orelse
                return client.sendMcpError(request_id, message_id, -32602, "missing params");
            const tool_name = stringField(params, "name") orelse
                return client.sendMcpError(request_id, message_id, -32602, "missing tool name");
            const arguments = objectField(params, "arguments") orelse std.json.Value{ .null = {} };

            const tool = server.findTool(tool_name) orelse
                return client.sendMcpError(request_id, message_id, -32601, "unknown tool");

            const call = tool.handler(tool.context, client.scratch.allocator(), arguments) catch |err| ToolResult{
                .text = @errorName(err),
                .is_error = true,
            };
            return client.sendMcpResultBody(
                request_id,
                message_id,
                protocol.results.toolCall,
                .{call},
            );
        }

        return client.sendMcpError(request_id, message_id, -32601, "unsupported mcp method");
    }

    // --- reading ---

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
