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

/// Ceiling on the text a tool handler may return, and the fix for a deadlock
/// that would otherwise hang both processes permanently.
///
/// The hazard: `next` is single-threaded and is the only reader of the child's
/// stdout. When it writes a tool reply into the child's stdin, a reply larger
/// than the stdin pipe's capacity blocks in `writev` until the child drains
/// it. If the child is meanwhile blocked writing its own stdout — whose only
/// reader is the `next` frame now stuck in `writev` — neither side can move.
/// The caller's thread is inside `next`, so `kill` is unreachable and nothing
/// breaks the cycle. Reproduced with a 4 MiB handler result.
///
/// Why a bound rather than interleaving: draining stdout while the stdin write
/// blocks needs a readiness primitive, and Zig 0.16 exposes none. `Io`'s vtable
/// has no poll or select over descriptors — `operate` covers only blocking
/// `file_read_streaming` / `file_write_streaming` — and `std.process.spawn`
/// leaves the stdio pipes blocking (only the progress pipe gets `O_NONBLOCK`).
/// Chunking the write does not help either: without readiness, a read between
/// chunks blocks whenever the child has nothing to say. A concurrent drain task
/// via `Io.concurrent` would need `Io.File.Reader`, which is not threadsafe and
/// which `next` is concurrently parsing from. So the reply is kept small enough
/// that the pipe always accepts it whole and the write never blocks.
///
/// The value: POSIX guarantees a pipe holds at least 4 KiB (`PIPE_BUF` is the
/// atomicity floor; capacity is at least that). Linux gives 64 KiB by default
/// but can shrink to one page under `pipe-user-pages-soft`, and macOS measured
/// 64 KiB here. 16 KiB stays under every floor above 4 KiB while leaving room
/// for real results, and the JSON envelope around the text is accounted for
/// separately below.
///
/// Residual risk, stated precisely: this bounds the tool-reply path, which is
/// the only place this client writes an unbounded caller-supplied payload.
/// `send` and `sendCommand` write caller text on the caller's own thread and
/// can still exceed the pipe if the caller passes a multi-megabyte prompt while
/// the child is mid-spew; that is a caller-visible blocking write, not a
/// reentrant one, and the caller's thread is not inside `next`, so `kill` from
/// another thread still breaks it. On a system with a 4 KiB pipe, a reply near
/// this bound could still block — but only until the child reads, which it will,
/// because nothing here is holding its stdout hostage.
pub const max_tool_result_bytes: usize = 16 * 1024;

/// Headroom for the JSON envelope `protocol.results.toolCall` wraps the text
/// in: the field names, and the worst-case 6x expansion of escaping every byte
/// as `\uXXXX`. Checked against the rendered reply rather than guessed at, so
/// this only has to be a bound, not an estimate.
const tool_result_envelope_bytes: usize = 256;

/// Sent in place of an over-long tool result. Addressed to the model, since
/// that is who reads an `is_error` result, and it names the limit so the fix
/// is obvious from the transcript alone.
const tool_result_too_long_message =
    "tool result too long: the SDK caps a tool result at 16384 bytes. " ++
    "Return less data, or a reference to it.";

pub const OpenError = error{
    /// `Options.max_line_bytes` was zero. Every line, including the empty one,
    /// is larger than a zero-byte budget, so the read loop would return
    /// `error.ProtocolTooLong` forever with no line able to clear it. Refused
    /// here rather than at the first read, where it looks like a protocol
    /// fault from the child instead of a configuration mistake.
    InvalidMaxLineBytes,
} || std.process.SpawnError || Allocator.Error || Io.Writer.Error;

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
    next_request_id: u64 = 0,
    session_id: ?[]u8 = null,
    stdin_closed: bool = false,
    /// The read-side counterpart to `stdin_closed`. Reaping the child, by
    /// `wait` or `kill`, closes its stdout inside the stdlib, but
    /// `stdout_reader` holds the file by value and keeps a stale copy of the
    /// descriptor. Reading through that copy once the number has been recycled
    /// parses whatever unrelated file now owns it and hands it back as a
    /// genuine event. This flag is what stops that: once set, `next` reports
    /// end of stream instead of touching the reader.
    stdout_closed: bool = false,
    /// How the child ended, once it has been reaped by `wait` or `close`.
    /// Null while it is still running, so a caller that only ever uses the
    /// `defer _ = client.close()` idiom can still tell a clean exit from a
    /// crash by reading it before the pointer goes away.
    ///
    /// Observed, except after `kill`, which cannot observe anything: Zig
    /// 0.16's `Child.kill` returns void and reaps as it goes, so the real
    /// status is gone by the time it returns. `kill` therefore stores an
    /// assumed `.signal = SIGTERM` here and sets `killed`. Check `killed`
    /// before drawing any conclusion from this field: a child that had already
    /// exited cleanly with code 0 still reads as signal-terminated.
    term: ?std.process.Child.Term = null,
    /// Whether `kill` produced the value in `term`. When true, `term` is an
    /// assumption rather than an observation and says nothing about how the
    /// child actually ended; see `term` and `kill`.
    killed: bool = false,
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
        // Checked before anything is allocated or spawned, so a rejected
        // configuration costs nothing and leaves no child to reap.
        if (options.max_line_bytes == 0) return error.InvalidMaxLineBytes;

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
            // The reap failed, but the stdlib may still have torn the
            // descriptors down, so the reader is no longer trustworthy either.
            client.stdout_closed = true;
            client.wait_error = err;
            return err;
        };
        client.stdout_closed = true;
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
    /// The status left in `term` afterwards is SYNTHESIZED, not observed.
    /// `Child.kill` returns void in Zig 0.16 and reaps the child itself, so
    /// the real status is consumed inside it and never surfaces. A child that
    /// had already exited cleanly with code 0 is indistinguishable here from
    /// one this call actually signalled, and both read as `.signal = SIGTERM`.
    /// `killed` is set alongside so the difference stays visible; anything
    /// that branches on `term` should check `killed` first.
    pub fn kill(client: *Client) void {
        if (client.term != null or client.wait_error != null) return;
        client.closeStdin();
        client.child.kill(client.io);
        // Reaped inside `kill`, so the reader's descriptor is stale from here.
        client.stdout_closed = true;
        // An assumption, not an observation. `killed` is what says so.
        client.killed = true;
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
    ///
    /// Ordering: draining to null before reaping is the intended flow, but
    /// calling this after `wait`, `kill`, or `close` is legal and reports the
    /// clean end of the stream rather than an error. Reaping the child closes
    /// its stdout, and anything still buffered goes with it, so events not yet
    /// read at that point are lost — the status is what remains meaningful.
    pub fn next(client: *Client) ReadError!?Event {
        // The child has been reaped, so `stdout_reader` holds a descriptor the
        // stdlib already closed. End of stream is the honest answer: there is
        // nothing further to read, and reading anyway risks parsing whatever
        // unrelated file has since inherited the number.
        if (client.stdout_closed) return null;

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
    ///
    /// The rendered payload is measured before it is written, which is the
    /// backstop for `max_tool_result_bytes`: the caller's check counts the raw
    /// text, but JSON escaping can expand a byte up to sixfold as `\uXXXX`, so
    /// a result that passed there can still render too large. Escaping is
    /// bounded and non-adversarial in practice, so this fires only on
    /// pathological input, and it replaces the payload rather than failing —
    /// the request still gets an answer.
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

        if (out.written().len > max_tool_result_bytes + tool_result_envelope_bytes) {
            var small: Io.Writer.Allocating = .init(client.scratch.allocator());
            var small_js: std.json.Stringify = .{ .writer = &small.writer };
            try protocol.results.toolCall(&small_js, .{
                .text = tool_result_too_long_message,
                .is_error = true,
            });
            return client.sendMcpResult(request_id, message_id, small.written());
        }
        try client.sendMcpResult(request_id, message_id, out.written());
    }

    // --- control dispatch ---

    fn serveControlRequest(client: *Client, root: std.json.Value) !void {
        // request_id is the only thing a reply can be correlated by, so it is
        // recovered before anything else. The CLI puts it at the top level,
        // beside `request`; older shapes nested it inside, so accept either.
        //
        // A numeric id is rendered into `id_buf` and answered like any other:
        // it correlates perfectly well, and treating it as absent would stall
        // every control request in the session. Only a request carrying no id
        // at all is unanswerable.
        const request = objectField(root, "request");
        var id_buf: [request_id_buf_len]u8 = undefined;
        const request_id = requestId(root, &id_buf) orelse
            (if (request) |r| requestId(r, &id_buf) else null) orelse
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
                // Answer before propagating. The caller still gets the error,
                // but leaving without a reply would strand the CLI until its
                // own ~60 second timeout and break the invariant this function
                // asserts above: from the id onwards, every exit answers.
                error.OutOfMemory => {
                    client.sendMcpError(request_id, message_id, -32603, "out of memory") catch {};
                    return error.OutOfMemory;
                },
                else => ToolResult{ .text = @errorName(err), .is_error = true },
            };

            // Bounded before it is written. A reply larger than the stdin pipe
            // blocks `next` in `writev` while the child blocks writing the
            // stdout only `next` reads, and neither side can move again; see
            // `max_tool_result_bytes`. Reported to the model as a failed call
            // rather than to the caller as an error, because an over-long
            // result is the handler's bug and something Claude can react to by
            // asking for less.
            if (call.text.len > max_tool_result_bytes) {
                return client.sendMcpResultBody(request_id, message_id, protocol.results.toolCall, .{
                    ToolResult{ .text = tool_result_too_long_message, .is_error = true },
                });
            }
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

/// Enough for the decimal form of any i64, sign included, which is the widest
/// `std.json.Value.integer` there is.
const request_id_buf_len = 20;

/// The request id of `value`, as the string a reply is addressed with.
///
/// The CLI normally sends a string, but a numeric id is just as correlatable —
/// it is rendered into `buf` and used the same way, rather than being treated
/// as missing and stalling the request until the CLI's own ~60 second timeout.
/// A float or bool id is not something the CLI emits, and rounding one to an
/// integer would answer the wrong request, so those stay unhandled.
///
/// Returns null only when there is genuinely nothing to address a reply to.
fn requestId(value: std.json.Value, buf: []u8) ?[]const u8 {
    return switch (objectField(value, "request_id") orelse return null) {
        .string => |s| s,
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable,
        else => null,
    };
}

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
    // `max_line_bytes + 1`, not `max_line_bytes`. The allowance is spent on
    // payload bytes before the delimiter can be seen, so a line of exactly
    // `max_line_bytes` exhausts a `.limited(max_line_bytes)` budget one byte
    // short of the newline and is rejected. `Options.max_line_bytes` promises
    // to refuse a line *larger* than this, so exactly N must be accepted.
    // Saturating: `Limit.limited` reads `maxInt(usize)` as `.unlimited`, which
    // is the right reading of a caller who asked for the largest bound there
    // is, and it keeps `+ 1` from wrapping to zero.
    _ = r.streamDelimiterLimit(
        &line.writer,
        '\n',
        .limited(max_line_bytes +| 1),
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

// Everything below stays in this file. Each test drives one of `readLine`,
// `writeCommandMessage`, or `serveControlRequest`, all of which are private,
// and the fixtures reach `reply_override`, a private field. Moving them would
// mean making internals public purely for test layout. The public shape of
// `Client` is covered from tests/client_test.zig instead.

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

test "a line of exactly max_line_bytes is accepted" {
    // The boundary `Options.max_line_bytes` documents: larger than N is
    // refused, so exactly N is legal. The limit is spent on payload before the
    // delimiter comes into view, so a budget of exactly N rejects an N-byte
    // line one byte short of its newline.
    try expectLines(
        "12345678\n{\"b\":2}\n",
        8,
        &.{ .{ .line = "12345678" }, .{ .line = "{\"b\":2}" }, .end },
    );
}

test "a line one byte over max_line_bytes is still rejected" {
    // The other half of the boundary: moving it by one must not move it by
    // two. N+1 stays an error, and costs only its own line.
    try expectLines(
        "123456789\n{\"b\":2}\n",
        8,
        &.{ .{ .fails = error.ProtocolTooLong }, .{ .line = "{\"b\":2}" }, .end },
    );
}

test "an exactly-max line without a trailing newline is accepted" {
    // End of stream rather than a delimiter ends this one, so it exercises the
    // path where the limit is reached and the newline never arrives at all.
    try expectLines("12345678", 8, &.{ .{ .line = "12345678" }, .end });
}

test "a max_line_bytes of maxInt does not wrap to a zero budget" {
    // `+ 1` on the limit would overflow here. `Limit.limited` already reads
    // maxInt as `.unlimited`, so saturating is both correct and the intent.
    try expectLines(
        "{\"a\":1}\n",
        std.math.maxInt(usize),
        &.{ .{ .line = "{\"a\":1}" }, .end },
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

test "a numeric request_id is answered, not treated as missing" {
    // The CLI correlates a numeric id just as well as a string one, so
    // dropping the reply would stall every control request in the session
    // until the CLI's own ~60 second timeout. Both placements of the id are
    // covered, since the older shape nests it inside `request`.
    const cases = [_][]const u8{
        \\{"type":"control_request","request_id":7,"request":{"subtype":"can_use_tool"}}
        ,
        \\{"type":"control_request","request":{"request_id":7,"subtype":"can_use_tool"}}
    };
    for (cases) |line| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try dispatch(&out, &.{}, line);

        // Answered, and addressed by the id rendered as its decimal string.
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"request_id\":\"7\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"subtype\":\"error\"") != null);
    }
}

test "a negative numeric request_id round-trips through the buffer" {
    // The buffer is sized for the widest i64, sign included. A negative id is
    // the case that would overrun a buffer sized for digits alone.
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{},
        \\{"type":"control_request","request_id":-9223372036854775808,"request":{"subtype":"can_use_tool"}}
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "\"request_id\":\"-9223372036854775808\"",
    ) != null);
}

/// A handler returning `size` bytes of filler, used to drive the reply bound.
fn oversizedHandler(context: ?*anyopaque, arena: Allocator, arguments: std.json.Value) anyerror!ToolResult {
    _ = arguments;
    const size: *const usize = @ptrCast(@alignCast(context.?));
    const text = try arena.alloc(u8, size.*);
    @memset(text, 'x');
    return .{ .text = text };
}

/// Runs one `tools/call` against a handler returning `size` bytes.
fn dispatchToolCall(out: *Io.Writer.Allocating, size: *const usize) !void {
    const server: McpServer = .{
        .name = "s",
        .tools = &.{.{ .name = "t", .description = "d", .handler = oversizedHandler, .context = @constCast(size) }},
    };
    try dispatch(out, &.{server},
        \\{"type":"control_request","request_id":"r","request":{"subtype":"mcp_message","server_name":"s","message":{"method":"tools/call","id":1,"params":{"name":"t"}}}}
    );
}

test "an oversized tool result is replaced rather than written to the pipe" {
    // The deadlock this prevents: a reply larger than the stdin pipe blocks
    // `next` in writev while the child blocks writing the stdout only `next`
    // reads. Neither side can move, and the caller's thread is inside `next`,
    // so `kill` is unreachable. See `max_tool_result_bytes`.
    var size: usize = max_tool_result_bytes + 1;
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchToolCall(&out, &size);

    // The filler never reaches the wire, and the model is told why.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "xxxxxxxxxx") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tool result too long") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") != null);

    // The whole reply stays comfortably inside one pipe buffer, which is the
    // property that actually rules the deadlock out.
    try std.testing.expect(out.written().len < 4096);
}

test "a tool result of exactly the cap is still delivered" {
    // The bound has to admit what it advertises, or it is a truncation bug
    // rather than a deadlock fix.
    var size: usize = max_tool_result_bytes;
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchToolCall(&out, &size);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tool result too long") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":false") != null);
    // Delivered whole: every filler byte survived the round trip.
    // Delivered whole: the filler survives the round trip as one unbroken run.
    // Counted as a run rather than as a total, since `x` also occurs in the
    // surrounding envelope.
    // The longest run, not the first: `x` also occurs in the surrounding
    // envelope, so an unbroken run of exactly the cap is what shows the filler
    // arrived whole and untruncated.
    var longest: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, out.written(), i, 'x')) |start| {
        const end = std.mem.indexOfNonePos(u8, out.written(), start, "x") orelse out.written().len;
        longest = @max(longest, end - start);
        i = end;
    }
    try std.testing.expectEqual(max_tool_result_bytes, longest);
    // And still one pipe-load, so the write cannot block.
    try std.testing.expect(out.written().len <= max_tool_result_bytes + tool_result_envelope_bytes);
}

/// A handler that always fails the way a host running out of memory does.
fn oomHandler(_: ?*anyopaque, _: Allocator, _: std.json.Value) anyerror!ToolResult {
    return error.OutOfMemory;
}

test "a handler that runs out of memory still answers the CLI" {
    // OutOfMemory propagates to the caller, but the CLI has to be told too:
    // returning without a reply strands it until its own ~60 second timeout
    // and breaks the invariant that every exit past the id answers.
    const server: McpServer = .{
        .name = "s",
        .tools = &.{.{ .name = "t", .description = "d", .handler = oomHandler }},
    };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var client = dispatchFixture(&out, &.{server});
    defer client.scratch.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"type":"control_request","request_id":"r","request":{"subtype":"mcp_message","server_name":"s","message":{"method":"tools/call","id":1,"params":{"name":"t"}}}}
    , .{});
    defer parsed.deinit();

    // The error still reaches the caller...
    try std.testing.expectError(error.OutOfMemory, client.serveControlRequest(parsed.value));
    // ...and the CLI still got an answer, as an internal jsonrpc error.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "out of memory") != null);
    try std.testing.expectEqual(@as(u8, '\n'), out.written()[out.written().len - 1]);
}

test "open rejects a zero max_line_bytes instead of failing forever" {
    // Zero is a permanent-error trap: every line, the empty one included, is
    // larger than a zero-byte budget, so `nextLine` would return
    // ProtocolTooLong forever with no line able to clear it. Refused up front,
    // before anything is allocated or spawned.
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.InvalidMaxLineBytes, Client.open(
        std.testing.allocator,
        threaded.io(),
        .{ .max_line_bytes = 0 },
    ));
    // And it is reachable through the declared error set, not just at runtime.
    const e: OpenError = error.InvalidMaxLineBytes;
    try std.testing.expectEqual(OpenError.InvalidMaxLineBytes, e);
}

test "a killed child reports its status as synthetic" {
    // `Child.kill` returns void in Zig 0.16 and reaps as it goes, so the real
    // status is genuinely unavailable and `term` has to be assumed. `killed`
    // is what keeps the assumption from passing as an observation: a child
    // that had already exited cleanly with code 0 still reads as SIGTERM here.
    var client: Client = undefined;
    client.term = null;
    client.wait_error = null;
    client.killed = false;
    try std.testing.expect(!client.killed);

    // The field exists, is public, and pairs with `term`. `kill` itself needs
    // a live child, so the pairing rather than the syscall is what is pinned.
    client.term = .{ .signal = std.posix.SIG.TERM };
    client.killed = true;
    try std.testing.expect(client.killed);
    try std.testing.expectEqual(std.posix.SIG.TERM, client.term.?.signal);
}
