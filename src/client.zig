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

/// Everything the write side of the public API can fail with. Declared rather
/// than inferred: an inferred set resolves through `std.json.Stringify`, so a
/// stdlib change would silently widen the public surface.
pub const WriteError = error{
    /// The write side is shut: `closeStdin` already ran. The writer holds the
    /// descriptor by value, so it cannot be nulled out from under it; refusing
    /// here is what keeps a post-close send off a recycled fd.
    StdinClosed,
    WriteFailed,
} || Allocator.Error;

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
    /// How the child ended, once it has been reaped by `wait` or `close`.
    /// Null while it is still running, so a caller that only ever uses the
    /// `defer _ = client.close()` idiom can still tell a clean exit from a
    /// crash by reading it before the pointer goes away.
    term: ?std.process.Child.Term = null,
    /// Test seam: when set, control replies are written here instead of to
    /// the child's stdin, so the dispatch can be exercised without a
    /// subprocess. Always null in normal use.
    reply_override: ?*Io.Writer = null,
    /// Set when reaping the child failed outright. A failed reap is not the
    /// same as a `.unknown` exit status, so it is recorded separately rather
    /// than folded into `term`.
    wait_error: ?std.process.Child.WaitError = null,

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

    /// Reaps the child and reports how it ended, without freeing the client.
    /// Call this when the exit status matters: a CLI that dies on startup
    /// produces zero events, so the read loop ends normally and the status is
    /// the only signal that anything went wrong.
    ///
    /// Closes stdin first, so a CLI waiting for more input finishes its turn
    /// and exits rather than blocking here. Idempotent: the reaped status is
    /// cached, so a later `close` returns the same value without waiting again.
    pub fn wait(client: *Client) std.process.Child.WaitError!std.process.Child.Term {
        if (client.term) |term| return term;
        if (client.wait_error) |err| return err;
        client.closeStdin();
        const term = client.child.wait(client.io) catch |err| {
            client.wait_error = err;
            return err;
        };
        client.term = term;
        return term;
    }

    /// Terminates the child without waiting for it to finish on its own, then
    /// reaps it. Use this when a wedged CLI must not hold up the host.
    ///
    /// This is the escape hatch for a child that never exits. `close` cannot
    /// bound its own wait: Zig 0.16's `Io` vtable has no timed or non-blocking
    /// child wait (`childWait` is a plain blocking `wait4`), and racing a
    /// `kill` against an in-flight `wait` on the same child is a double-reap
    /// that trips an assert in the stdlib. Running the wait under an
    /// `Io.Select` timeout does not help either: cancelling the wait clears
    /// `child.id`, which discards the very handle needed to escalate. So the
    /// deadline belongs to the caller, who alone knows what "too long" means.
    pub fn kill(client: *Client) void {
        if (client.term != null or client.wait_error != null) return;
        client.closeStdin();
        client.child.kill(client.io);
        // `kill` reaps as it goes, so there is no status left to collect.
        client.term = .{ .signal = std.posix.SIG.TERM };
    }

    /// Reaps the child and releases the client. The returned status is safe to
    /// discard when it does not matter; when it does, prefer `wait` before
    /// this, or read `term` on the way past.
    ///
    /// A failed reap surfaces as `.unknown` here only because this signature
    /// cannot carry an error. `wait` reports it properly.
    pub fn close(client: *Client) std.process.Child.Term {
        const term = client.wait() catch std.process.Child.Term{ .unknown = 0 };
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

    /// The session id the CLI assigned, once any event has carried one. Pass
    /// it back as `Options.resume_session_id` to resume this conversation.
    /// Valid until `close`.
    pub fn sessionId(client: *const Client) ?[]const u8 {
        return client.session_id;
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

    /// The writer for the child's stdin, or `error.StdinClosed` once
    /// `closeStdin` has run. `Io.File.Writer` stores the file by value, so
    /// closing the descriptor leaves the writer holding a stale copy of it;
    /// this check is what stops a late write landing on a recycled fd. It is a
    /// returned error rather than an assert because asserts vanish under
    /// `ReleaseFast` and `ReleaseSmall`, exactly where the fd may be reused.
    fn stdin(client: *Client) WriteError!*Io.Writer {
        if (client.stdin_closed) return error.StdinClosed;
        return &client.stdin_writer.interface;
    }

    /// Queues a user turn. Safe to call while a turn is in flight; the CLI
    /// treats it as mid-turn guidance.
    pub fn send(client: *Client, text: []const u8) WriteError!void {
        const w = try client.stdin();
        try protocol.writeUserMessage(w, text);
        try finishLine(w);
    }

    /// Dispatches a skill or command by name, optionally with arguments.
    /// Dispatch works even for skills the session's skill list omits.
    ///
    /// The `/name arguments` text is streamed straight into the stdin writer
    /// in escaped pieces, so no intermediate buffer is allocated and the error
    /// set carries no `Allocator.Error` from this path. Writing a partial line
    /// and then failing is harmless: the CLI acts on a line only once its
    /// newline lands, and no newline is written on the failing path.
    pub fn sendCommand(client: *Client, name: []const u8, arguments: []const u8) WriteError!void {
        const w = try client.stdin();
        try writeCommandMessage(w, name, arguments);
        try finishLine(w);
    }

    /// Asks the CLI to abandon the turn in progress.
    pub fn interrupt(client: *Client) WriteError!void {
        _ = try client.stdin();
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
                if (event.sessionId()) |id| {
                    // The tree owns the borrowed `id`, so it has to outlive the
                    // dupe, and has to be freed if the dupe is what fails.
                    errdefer event.deinit();
                    client.session_id = try client.gpa.dupe(u8, id);
                }
            }

            switch (event.kind) {
                .control_request, .sdk_control_request => {
                    defer event.deinit();
                    // Running out of memory is a host condition, not a dead
                    // child, and the two call for opposite responses: retry
                    // versus restart. Only genuine write failures collapse.
                    client.serveControlRequest(event.parsed.value) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.WriteFailed,
                    };
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

    /// Where replies go. Normally the child's stdin; tests point it at a
    /// buffer to read back what the dispatch answered.
    fn replyWriter(client: *Client) *Io.Writer {
        return client.reply_override orelse &client.stdin_writer.interface;
    }

    /// Writes one line by handing a `Stringify` over stdin to `f`.
    fn writeLine(client: *Client, comptime f: anytype, args: anytype) !void {
        const w = client.replyWriter();
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
        // request_id is the only thing a reply can be correlated by, so it is
        // recovered before anything else. The CLI puts it at the top level,
        // beside `request`; older shapes nested it inside, so accept either.
        const request = objectField(root, "request");
        const request_id = stringField(root, "request_id") orelse
            (if (request) |r| stringField(r, "request_id") else null) orelse
            // Nothing to address a reply to. This is the one path where
            // silence is unavoidable rather than chosen: the CLI keys its
            // pending requests by id, so a response without one is discarded
            // and answering is indistinguishable from not answering. Such a
            // request is malformed on the CLI's side, and it will time out on
            // its own.
            return;

        // From here on every exit answers. An unanswered request leaves the
        // CLI blocked until its own ~60 second timeout.
        const req = request orelse
            return client.sendControlError(request_id, "missing request body");
        const subtype = stringField(req, "subtype") orelse
            return client.sendControlError(request_id, "missing request subtype");

        if (!std.mem.eql(u8, subtype, "mcp_message")) {
            // Anything else, notably permission prompts, is not implemented
            // here. Answer rather than leave the CLI blocked for 60 seconds.
            return client.sendControlError(request_id, "unsupported control request");
        }

        const server_name = stringField(req, "server_name") orelse "";
        const message = objectField(req, "message") orelse
            return client.sendControlError(request_id, "missing mcp message");
        const method = stringField(message, "method") orelse
            return client.sendControlError(request_id, "missing mcp method");
        const message_id = objectField(message, "id");

        const server = tool_mod.findServer(client.servers, server_name) orelse
            return client.sendMcpError(request_id, message_id, -32601, "unknown server");

        // Reset before the handler runs, not after. The rendered result at
        // `sendMcpResultBody` lives in this arena and has to stay valid until
        // the reply is written, so resetting afterwards would either free it
        // too early or need a second arena. Resetting on the way in bounds the
        // memory just as well, since the result is only ever one dispatch old.
        // `tool.zig` documents the contract to match.
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

            // A handler-domain failure is something Claude can see and react
            // to, so it becomes an `is_error` result. Running out of memory is
            // not: it is a host condition, and reporting it to the model as
            // tool text would carry on in a degraded state instead of
            // surfacing it to the caller.
            const call = tool.handler(tool.context, client.scratch.allocator(), arguments) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => ToolResult{ .text = @errorName(err), .is_error = true },
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
        return readLine(&client.stdout_reader.interface, &client.line, client.max_line_bytes);
    }
};

/// The `/name arguments` turn, assembled straight into `w`. Split out from
/// `Client` so the escaping can be tested without a subprocess.
///
/// This is the same wire shape `protocol.writeUserMessage` produces, with the
/// text built in place instead of in a temporary buffer.
/// `encodeJsonStringChars` escapes a fragment without the surrounding quotes,
/// which is what lets the pieces be concatenated inside one JSON string.
fn writeCommandMessage(w: *Io.Writer, name: []const u8, arguments: []const u8) WriteError!void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("type");
    try js.write("user");
    try js.objectField("message");
    try js.beginObject();
    try js.objectField("role");
    try js.write("user");
    try js.objectField("content");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("type");
    try js.write("text");
    try js.objectField("text");
    try js.beginWriteRaw();
    try w.writeByte('"');
    try w.writeByte('/');
    try std.json.Stringify.encodeJsonStringChars(name, .{}, w);
    if (arguments.len > 0) {
        try w.writeByte(' ');
        try std.json.Stringify.encodeJsonStringChars(arguments, .{}, w);
    }
    try w.writeByte('"');
    js.endWriteRaw();
    try js.endObject();
    try js.endArray();
    try js.endObject();
    try js.endObject();
}

/// One newline-delimited line from `r`, buffered through `line`. Split out
/// from `Client` so the resync behaviour can be tested against a plain reader
/// rather than a live subprocess.
fn readLine(
    r: *Io.Reader,
    line: *Io.Writer.Allocating,
    max_line_bytes: usize,
) ReadError!?[]const u8 {
    line.clearRetainingCapacity();
    _ = r.streamDelimiterLimit(
        &line.writer,
        '\n',
        .limited(max_line_bytes),
    ) catch |err| switch (err) {
        // The limit was hit partway through a line, so the rest of it,
        // newline included, is still queued. Left there it would be read
        // as the start of the next line and overrun the limit again, and
        // every later call would fail the same way forever. Discarding
        // through the newline resyncs to a clean line boundary, so this
        // error costs one line rather than the whole stream.
        error.StreamTooLong => {
            _ = r.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                // The stream ended inside the oversized line. There is no
                // boundary left to resync to, but there is nothing after
                // it either, so the next call reports end of stream.
                error.EndOfStream => {},
                error.ReadFailed => return error.ReadFailed,
            };
            return error.ProtocolTooLong;
        },
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
    };

    // streamDelimiterLimit leaves the delimiter buffered. An empty buffer
    // instead means the stream ended.
    if (r.bufferedLen() == 0) {
        const written = line.written();
        return if (written.len == 0) null else written;
    }
    r.toss(1);
    return line.written();
}

// --- tests ---

/// What one `readLine` call should produce: a line, the clean end of the
/// stream, or an error.
const Expected = union(enum) {
    line: []const u8,
    end,
    fails: ReadError,
};

/// Drives `readLine` over a fixed buffer, the way `next` drives it over the
/// child's stdout.
fn expectLines(input: []const u8, max_line_bytes: usize, expected: []const Expected) !void {
    var r: Io.Reader = .fixed(input);
    var line: Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();

    for (expected) |want| switch (want) {
        .line => |text| try std.testing.expectEqualStrings(
            text,
            (try readLine(&r, &line, max_line_bytes)).?,
        ),
        .end => try std.testing.expect(try readLine(&r, &line, max_line_bytes) == null),
        .fails => |err| try std.testing.expectError(err, readLine(&r, &line, max_line_bytes)),
    };
}

test "an oversized line costs one line, not the stream" {
    // Without the resync, the tail of the oversized line stays queued and
    // every later read fails the same way forever.
    try expectLines(
        "{\"a\":1}\nxxxxxxxxxxxxxxxxxxxx\n{\"b\":2}\n{\"c\":3}\n",
        8,
        &.{
            .{ .line = "{\"a\":1}" },
            .{ .fails = error.ProtocolTooLong },
            .{ .line = "{\"b\":2}" },
            .{ .line = "{\"c\":3}" },
            .end,
        },
    );
}

test "an oversized line at end of stream still terminates" {
    // Nothing follows the oversized line, so there is no boundary to resync
    // to and the next read has to report end of stream rather than loop.
    try expectLines(
        "xxxxxxxxxxxxxxxxxxxx",
        8,
        &.{ .{ .fails = error.ProtocolTooLong }, .end },
    );
}

test "lines are returned whole and the stream ends cleanly" {
    try expectLines(
        "{\"a\":1}\n{\"b\":2}\n",
        1024,
        &.{ .{ .line = "{\"a\":1}" }, .{ .line = "{\"b\":2}" }, .end },
    );
}

test "a trailing line without a newline is still returned" {
    try expectLines(
        "{\"a\":1}\n{\"b\":2}",
        1024,
        &.{ .{ .line = "{\"a\":1}" }, .{ .line = "{\"b\":2}" }, .end },
    );
}

test "the write API declares an explicit error set" {
    // Inferred sets resolve through std.json.Stringify, so a stdlib change
    // would silently widen the public surface. Pin the three signatures.
    const Fn = @typeInfo(@TypeOf(Client.send)).@"fn";
    try std.testing.expectEqual(WriteError!void, Fn.return_type.?);
    try std.testing.expectEqual(
        WriteError!void,
        @typeInfo(@TypeOf(Client.sendCommand)).@"fn".return_type.?,
    );
    try std.testing.expectEqual(
        WriteError!void,
        @typeInfo(@TypeOf(Client.interrupt)).@"fn".return_type.?,
    );
    // StdinClosed is what a post-closeStdin write reports instead of landing
    // on a stale descriptor, so it has to stay in the set. Coercing it is a
    // compile error if it is ever dropped.
    const closed: WriteError = error.StdinClosed;
    try std.testing.expectEqual(WriteError.StdinClosed, closed);
}

test "sendCommand builds the command turn without a temporary buffer" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCommandMessage(&out.writer, "code-review", "src/ \"quoted\"");

    // The same envelope a plain user turn uses, so the CLI sees no difference.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        out.written(),
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("user", stringField(parsed.value, "type").?);
    const message = objectField(parsed.value, "message").?;
    try std.testing.expectEqualStrings("user", stringField(message, "role").?);
    const content = objectField(message, "content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    // The quotes in the arguments have to survive as data, not terminate the
    // JSON string early.
    try std.testing.expectEqualStrings(
        "/code-review src/ \"quoted\"",
        stringField(content[0], "text").?,
    );
}

test "sendCommand omits the separator when there are no arguments" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCommandMessage(&out.writer, "compact", "");

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        out.written(),
        .{},
    );
    defer parsed.deinit();

    const content = objectField(objectField(parsed.value, "message").?, "content").?.array.items;
    try std.testing.expectEqualStrings("/compact", stringField(content[0], "text").?);
}

/// A client with just the fields the control dispatch touches, wired to write
/// its replies into `out`. Everything else stays undefined: the dispatch never
/// reaches the child, the reader, or the argv arena.
fn dispatchFixture(out: *Io.Writer.Allocating, servers: []const McpServer) Client {
    var client: Client = undefined;
    client.gpa = std.testing.allocator;
    client.scratch = .init(std.testing.allocator);
    client.servers = servers;
    client.reply_override = &out.writer;
    return client;
}

/// Runs one control request through the dispatch and hands back what it wrote.
fn dispatch(out: *Io.Writer.Allocating, servers: []const McpServer, line: []const u8) !void {
    var client = dispatchFixture(out, servers);
    defer client.scratch.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        line,
        .{},
    );
    defer parsed.deinit();
    try client.serveControlRequest(parsed.value);
}

test "every malformed control request that can be answered is answered" {
    // The invariant: an unsupported or malformed control request gets an error
    // response rather than silence, so the CLI does not block until its own
    // ~60 second timeout.
    const cases = [_][]const u8{
        // No `request` object at all, but the id is at the top level.
        \\{"type":"control_request","request_id":"r1"}
        ,
        // A request body with no subtype to dispatch on.
        \\{"type":"control_request","request_id":"r2","request":{}}
        ,
        // A subtype this client does not implement, such as a permission
        // prompt.
        \\{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool"}}
        ,
        // Older shape: the id is nested inside `request` rather than beside it.
        \\{"type":"control_request","request":{"request_id":"r4"}}
        ,
    };

    for (cases, [_][]const u8{ "r1", "r2", "r3", "r4" }) |line, id| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try dispatch(&out, &.{}, line);

        // Something was written, and it is addressed to the right request.
        try std.testing.expect(out.written().len > 0);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"control_response\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"subtype\":\"error\"") != null);
        const quoted = try std.fmt.allocPrint(std.testing.allocator, "\"request_id\":\"{s}\"", .{id});
        defer std.testing.allocator.free(quoted);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), quoted) != null);
        // A reply is one line, terminated, so the CLI acts on it.
        try std.testing.expectEqual(@as(u8, '\n'), out.written()[out.written().len - 1]);
    }
}

test "a control request with no id is the only silent path" {
    // Nothing to correlate a reply to, so answering is indistinguishable from
    // not answering. Documented as unavoidable rather than chosen.
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{},
        \\{"type":"control_request","request":{"subtype":"can_use_tool"}}
    );
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "an mcp request against an unknown server gets a jsonrpc error" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{},
        \\{"type":"control_request","request_id":"r5","request":{"subtype":"mcp_message","server_name":"nope","message":{"method":"tools/list","id":1}}}
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "unknown server") != null);
}
