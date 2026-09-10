// src/client.zig
// Process lifecycle and the read loop: spawns the CLI, pumps protocol lines,
// and services the control traffic that in-process tools arrive on.

const std = @import("std");
const builtin = @import("builtin");
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
const PermissionHandler = tool_mod.PermissionHandler;
const PermissionDecision = tool_mod.PermissionDecision;

/// Ceiling on the text a tool handler may return, and the fix for a deadlock.
///
/// `next` is the only reader of the child's stdout. A tool reply larger than
/// the stdin pipe blocks in `writev` until the child drains it, while the child
/// blocks writing the stdout only that same `next` frame reads. Neither side
/// can move, and the caller's thread is inside `next`, so `kill` is
/// unreachable. Keeping the reply under one pipe-load is what rules this out;
/// Zig 0.16 has no readiness primitive to interleave the two with.
///
/// 16 KiB because POSIX guarantees a pipe holds at least 4 KiB, and Linux and
/// macOS give 64 KiB in practice. The bound that is actually enforced is
/// `max_reply_line_bytes`, measured on the whole rendered line — envelope,
/// ids and newline included — since that is what lands in the pipe.
pub const max_tool_result_bytes: usize = 16 * 1024;

/// Headroom over `max_tool_result_bytes` for everything around the text: the
/// `control_response` envelope, the CLI's `request_id`, the JSON-RPC id, and
/// the `toolCall` fields. Generous rather than exact, because the ids are the
/// CLI's to size. Escaping is not budgeted here: it can expand a byte up to
/// sixfold as `\uXXXX`, so the rendered line is measured instead of estimated.
const tool_result_envelope_bytes: usize = 512;

/// The most this process writes to the child in one reply line. Every reply
/// that carries caller- or CLI-sized data is rendered first and measured
/// against this; one that does not fit is replaced by a short one that says
/// why, so the request is still answered.
const max_reply_line_bytes: usize = max_tool_result_bytes + tool_result_envelope_bytes;

/// Sent in place of an over-long tool result. Addressed to the model, since
/// that is who reads an `is_error` result, and it names the limit so the fix
/// is obvious from the transcript alone.
const tool_result_too_long_message =
    "tool result too long: the SDK caps a tool result at 16384 bytes. " ++
    "Return less data, or a reference to it.";

/// Past this, the scratch arena and the line buffer are shrunk rather than
/// retained on the next use. Below it, both keep their capacity, so the usual
/// small line costs no allocation. One event near `max_line_bytes` would
/// otherwise pin its size for the rest of the session.
const retain_bytes: usize = 1024 * 1024;

/// How many of this client's own control requests may await an answer. Only
/// `initialize` and `interrupt` send one, and the CLI answers each promptly,
/// so this is a ceiling on a list that is normally empty, not a queue depth.
/// Fixed so that generating an id never allocates.
const max_pending_requests = 16;

pub const OpenError = error{
    /// `Options.max_line_bytes` was zero, which no line can ever satisfy, so
    /// the read loop would fail forever. Refused here rather than at the first
    /// read, where it would look like a protocol fault from the child.
    InvalidMaxLineBytes,
    /// A `Tool.input_schema` is not a JSON object. It is spliced into the
    /// `tools/list` reply verbatim, so a malformed one would corrupt the frame
    /// rather than fail; checked before anything is spawned.
    InvalidToolSchema,
} || std.process.SpawnError || Allocator.Error || Io.Writer.Error;

/// Everything the write side of the public API can fail with. Declared rather
/// than inferred: an inferred set resolves through `std.json.Stringify`, so a
/// stdlib change would silently widen the public surface.
///
/// No allocation error, because no write path allocates: `send` and
/// `interrupt` render straight into the stdin writer's buffer, and
/// `sendCommand` streams its text in escaped pieces for the same reason.
pub const WriteError = error{
    /// `closeStdin` already ran. The writer holds the descriptor by value, so
    /// refusing here keeps a post-close send off a recycled fd.
    StdinClosed,
    WriteFailed,
};

pub const ReadError = error{
    ProtocolTooLong,
    ReadFailed,
    WriteFailed,
    InvalidJson,
    /// A control request arrived that this process must answer, but the write
    /// side is already shut. Reported rather than swallowed: see `replyWriter`.
    StdinClosed,
    /// The CLI answered a request this client sent — the `initialize`
    /// handshake, or an `interrupt` — with an error. The text is in
    /// `lastControlError`. The stream itself is intact, so reading on is
    /// legal, but a rejected `initialize` means the session has no SDK tools
    /// and no skill allowlist, whatever `Options` asked for.
    ControlRequestRejected,
} || Allocator.Error;

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    stdin_buffer: []u8,
    stdout_buffer: []u8,
    stdin_writer: Io.File.Writer,
    stdout_reader: Io.File.Reader,
    line: Io.Writer.Allocating,
    max_line_bytes: usize,
    servers: []const McpServer,
    /// Borrowed from `Options`, like `servers`, so the caller keeps it alive.
    skills: ?[]const []const u8,
    permission_handler: ?PermissionHandler,
    permission_context: ?*anyopaque,
    scratch: std.heap.ArenaAllocator,
    next_request_id: u64 = 0,
    /// The numbers of this client's own `zig_N` requests still awaiting a
    /// `control_response`, oldest first. Matched in `next` so an error reply
    /// to one of them is reported rather than dropped.
    pending_requests: [max_pending_requests]u64 = undefined,
    pending_len: usize = 0,
    /// The text of the last error `control_response` addressed to one of this
    /// client's requests. Owned; see `lastControlError`.
    control_error: ?[]u8 = null,
    session_id: ?[]u8 = null,
    stdin_closed: bool = false,
    /// The read-side counterpart to `stdin_closed`: set by the reap, after
    /// which `next` reports end of stream rather than reading on. Whatever
    /// the child left in the pipe is dropped, since only the exit status is
    /// meaningful once it is gone. The descriptor itself stays open until
    /// `close` — see `open` — so a reader mid-`read` on another thread is
    /// not cut off; the child dying is what ends its read.
    stdout_closed: bool = false,
    /// How the child ended, once it has been reaped by `wait`, `kill`, or
    /// `close`. Null while it is still running, so a caller that only ever
    /// uses the `defer _ = client.close()` idiom can still tell a clean exit
    /// from a crash by reading it before the pointer goes away.
    ///
    /// Always the status the kernel reported. Stable from the moment the
    /// caller's own `wait` or `kill` returns; another thread reads it safely
    /// through `wait`, which hands back the cached value.
    term: ?std.process.Child.Term = null,
    /// Whether `kill` sent `SIGTERM` before the child was reaped. Says why
    /// the child died, not how: `term` still holds the observed status, and
    /// a child that traps the signal reads as `.exited`. Stable under the
    /// same rule as `term`.
    killed: bool = false,
    /// Test seam: when set, control replies are written here instead of to
    /// the child's stdin, so the dispatch can be exercised without a
    /// subprocess. `void` outside a test build, so it cannot be set there.
    reply_override: if (builtin.is_test) ?*Io.Writer else void = if (builtin.is_test) null else {},
    /// Set when reaping the child failed outright, and not folded into
    /// `term`: a failed reap is not a `.unknown` exit status. Stable under
    /// the same rule as `term`.
    wait_error: ?std.process.Child.WaitError = null,
    /// Set when the final flush in `closeStdin` failed, meaning buffered
    /// protocol bytes were dropped before the descriptor went away.
    ///
    /// Recorded rather than returned, since `closeStdin` is called from `wait`
    /// and `kill`, neither of which can carry it. A swallowed flush loses a
    /// queued turn with no signal, which reads downstream as a CLI that ignored
    /// a message. Stable once the caller's own `closeStdin`, `wait`, or
    /// `kill` has returned.
    flush_error: ?Io.Writer.Error = null,
    /// The child's pid, captured at spawn. `kill` signals through it rather
    /// than through `child`, which the thread inside a reap owns.
    pid: std.process.Child.Id,
    /// Serializes the write side: the stdin writer, `stdin_closed`,
    /// `flush_error`, and the `zig_N` request bookkeeping. Held for one line
    /// and its flush, never while a tool or permission handler runs, so a
    /// handler may `send`.
    write_mutex: Io.Mutex = .init,
    /// Serializes `next`: the line buffer, the scratch arena, and dispatch.
    /// Not reentrant, so a handler must not call `next`. `close` takes it
    /// after reaping so it cannot free the client under a reader.
    read_mutex: Io.Mutex = .init,
    /// Guards the lifecycle fields: `term`, `killed`, `wait_error`,
    /// `stdout_closed`, `session_id`, and `waiting`. Never held across a
    /// blocking call, and never held while taking another lock.
    state_mutex: Io.Mutex = .init,
    /// Broadcast under `state_mutex` when a reap finishes; see `waiting`.
    reaped: Io.Condition = .init,
    /// True while one thread is inside the blocking reap. That thread owns
    /// `child`; a second `wait` sleeps on `reaped` rather than reaping again,
    /// and `kill` signals `pid` and lets the reaper observe the death.
    waiting: bool = false,

    /// Spawns the CLI. The returned pointer is stable; the reader and writer
    /// interfaces embed pointers into it.
    pub fn open(gpa: Allocator, io: Io, options: Options) OpenError!*Client {
        // Checked before anything is allocated or spawned, so a rejected
        // configuration costs nothing and leaves no child to reap.
        if (options.max_line_bytes == 0) return error.InvalidMaxLineBytes;
        for (options.sdk_mcp_servers) |server| {
            for (server.tools) |tool| {
                if (!try isJsonObject(gpa, tool.input_schema)) return error.InvalidToolSchema;
            }
        }

        const client = try gpa.create(Client);
        errdefer gpa.destroy(client);

        const stdin_buffer = try gpa.alloc(u8, options.stdin_buffer_size);
        errdefer gpa.free(stdin_buffer);
        const stdout_buffer = try gpa.alloc(u8, options.stdout_buffer_size);
        errdefer gpa.free(stdout_buffer);

        // The argv is consumed by `spawn`; `Child` keeps no reference to it,
        // so the arena is gone before the client is even assembled.
        var child = blk: {
            var argv_arena: std.heap.ArenaAllocator = .init(gpa);
            defer argv_arena.deinit();
            const argv = try options_mod.buildArgv(argv_arena.allocator(), options);
            break :blk try std.process.spawn(io, .{
                .argv = argv,
                .cwd = options.cwd,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            });
        };
        errdefer child.kill(io);

        // Moved out of `child` so a reap cannot close it. The stdlib closes
        // every descriptor `child` still holds when it reaps, and `wait` or
        // `kill` on one thread would then close stdout under a `next` blocked
        // on another, leaving the reader to parse whatever file next took the
        // number. Owned here instead, and closed by `close`, last.
        const stdout_file = child.stdout.?;
        child.stdout = null;
        errdefer stdout_file.close(io);

        client.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .stdin_buffer = stdin_buffer,
            .stdout_buffer = stdout_buffer,
            .stdin_writer = child.stdin.?.writerStreaming(io, stdin_buffer),
            .stdout_reader = stdout_file.readerStreaming(io, stdout_buffer),
            .pid = child.id.?,
            .line = .init(gpa),
            .max_line_bytes = options.max_line_bytes,
            .servers = options.sdk_mcp_servers,
            .skills = options.skills,
            .permission_handler = options.permission_handler,
            .permission_context = options.permission_context,
            .scratch = .init(gpa),
        };

        // The errdefers above were registered before `line` and `scratch`
        // existed, so they cannot unwind them. Both allocate lazily and hold
        // nothing yet, but that stops being true the moment anything before
        // `return` grows either one.
        errdefer client.line.deinit();
        errdefer client.scratch.deinit();

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
    ///
    /// Safe from any thread. A second caller arriving while the reap is in
    /// flight sleeps until it finishes and returns the same status, and a
    /// `kill` from another thread ends the wait early; see `kill`.
    pub fn wait(client: *Client) std.process.Child.WaitError!std.process.Child.Term {
        const io = client.io;
        client.state_mutex.lockUncancelable(io);
        // Another thread is inside the reap. Its result is this one's too.
        while (client.waiting) client.reaped.waitUncancelable(io, &client.state_mutex);
        if (client.term) |term| {
            client.state_mutex.unlock(io);
            return term;
        }
        if (client.wait_error) |err| {
            client.state_mutex.unlock(io);
            return err;
        }
        client.waiting = true;
        client.state_mutex.unlock(io);
        return client.reap();
    }

    /// Terminates the child without waiting for it to finish on its own, then
    /// reaps it. Use this when a wedged CLI must not hold up the host.
    ///
    /// Safe from any thread, including a watchdog while another thread sits
    /// in `wait` or `close`: the child is signalled by pid, and the thread
    /// already inside the reap observes the death and records it, so there is
    /// exactly one reap. `term` is therefore the status the kernel reported,
    /// not an assumption; a child that traps `SIGTERM` and exits cleanly reads
    /// as `.exited`. `killed` says the signal was sent before the child was
    /// reaped, whatever it then died of.
    ///
    /// A no-op once `term` records a reap, and once a failed reap has already
    /// taken the pid — the process is gone either way, and signalling a pid
    /// the kernel may have reissued is worse than nothing.
    pub fn kill(client: *Client) void {
        const io = client.io;
        client.state_mutex.lockUncancelable(io);
        if (client.term != null) {
            client.state_mutex.unlock(io);
            return;
        }
        if (client.waiting) {
            // Another thread owns `child` for the duration of its reap. The
            // signal is sent under the lock, right after confirming that reap
            // has not yet recorded a result, which is as close as a pid-based
            // kill can get to not racing a reissued pid.
            client.killed = true;
            client.signal();
            client.state_mutex.unlock(io);
            return;
        }
        if (client.child.id == null) {
            // A failed reap: the stdlib has cleared the handle, so the child
            // is reaped or unreachable, and the pid may already be someone
            // else's.
            client.state_mutex.unlock(io);
            return;
        }
        client.waiting = true;
        client.killed = true;
        client.signal();
        client.state_mutex.unlock(io);
        _ = client.reap() catch {};
    }

    /// `SIGTERM` to the child, by pid. Called under `state_mutex` with the
    /// child known to be unreaped, so the pid is this process's own live or
    /// zombie child: it cannot be missing, and it cannot be someone else's.
    /// The only failure left is a kernel refusal, and the reap that follows
    /// is the right response to that too, so nothing is reported.
    fn signal(client: *Client) void {
        std.posix.kill(client.pid, .TERM) catch {};
    }

    /// The blocking reap. The caller has claimed `waiting` under
    /// `state_mutex`, so this thread owns `child` until it clears the flag.
    /// Records the outcome, marks the reader's stream ended, and wakes every
    /// thread queued in `wait`.
    fn reap(client: *Client) std.process.Child.WaitError!std.process.Child.Term {
        const io = client.io;
        client.closeStdin();
        const result = client.child.wait(io);

        client.state_mutex.lockUncancelable(io);
        defer client.state_mutex.unlock(io);
        client.waiting = false;
        client.stdout_closed = true;
        if (result) |term| {
            client.term = term;
        } else |err| {
            // A failed reap is not the same as a `.unknown` exit status, so
            // it is recorded separately rather than folded into `term`.
            client.wait_error = err;
        }
        client.reaped.broadcast(io);
        return result;
    }

    /// Reaps the child and releases the client. The returned status is safe to
    /// discard when it does not matter; when it does, prefer `wait` before
    /// this, or read `term` on the way past.
    ///
    /// A failed reap surfaces as `.unknown` here only because this signature
    /// cannot carry an error. `wait` reports it properly.
    ///
    /// Must be the last call on the client, like a free. The one overlap it
    /// tolerates is the common near miss: a reader still stepping out of
    /// `next` after the child died. Taking the read lock orders this free
    /// after that return.
    pub fn close(client: *Client) std.process.Child.Term {
        const term = client.wait() catch std.process.Child.Term{ .unknown = 0 };
        client.read_mutex.lockUncancelable(client.io);
        client.read_mutex.unlock(client.io);
        // Owned since `open`; the reap left it alone. Closed only now, when
        // no reader can be inside `next`.
        client.stdout_reader.file.close(client.io);
        const gpa = client.gpa;
        if (client.session_id) |id| gpa.free(id);
        if (client.control_error) |text| gpa.free(text);
        client.scratch.deinit();
        client.line.deinit();
        gpa.free(client.stdin_buffer);
        gpa.free(client.stdout_buffer);
        gpa.destroy(client);
        return term;
    }

    /// The session id the CLI assigned, once any event has carried one. Pass
    /// it back as `Options.resume_session_id` to resume this conversation.
    /// Valid until `close`, from any thread: set once by `next` and never
    /// replaced.
    pub fn sessionId(client: *Client) ?[]const u8 {
        client.state_mutex.lockUncancelable(client.io);
        defer client.state_mutex.unlock(client.io);
        return client.session_id;
    }

    /// The raw bytes of the most recent protocol line `next` read, whatever
    /// became of it: the line behind the event it returned, the line that
    /// failed to parse when it returned `error.InvalidJson`, or the prefix
    /// that fit before `error.ProtocolTooLong` cut the rest off. Empty before
    /// the first read, and after end of stream.
    ///
    /// Valid until the next call to `next`, which reuses the buffer. Log it
    /// there, or copy it; do not keep the slice. Belongs to the thread that
    /// called `next`: another thread's `next` may be rewriting it.
    pub fn lastLine(client: *const Client) []const u8 {
        return client.line.writer.buffered();
    }

    /// The error text from the last `control_response` the CLI addressed to
    /// one of this client's own requests, once `next` has returned
    /// `error.ControlRequestRejected`. Null until then. Replaced by the next
    /// such error and freed by `close`; valid in between, on the thread that
    /// called `next`.
    pub fn lastControlError(client: *const Client) ?[]const u8 {
        return client.control_error;
    }

    /// Signals end of input. The CLI finishes the current turn and exits.
    ///
    /// The final flush can fail — the child may have died with bytes still
    /// buffered — and the descriptor is closed regardless, because leaking it
    /// helps nobody. The failure is recorded in `flush_error` rather than
    /// returned: this is called from `wait` and from `kill`, neither of which
    /// can carry it. Check `flush_error` when it matters that the last line
    /// actually left this process.
    pub fn closeStdin(client: *Client) void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        if (client.stdin_closed) return;
        client.stdin_closed = true;
        client.stdin_writer.interface.flush() catch |err| {
            client.flush_error = err;
        };
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
    ///
    /// Caller holds `write_mutex`.
    fn stdin(client: *Client) WriteError!*Io.Writer {
        if (client.stdin_closed) return error.StdinClosed;
        return &client.stdin_writer.interface;
    }

    /// Queues a user turn. Safe to call while a turn is in flight; the CLI
    /// treats it as mid-turn guidance. Safe from any thread, including a
    /// handler running inside another thread's `next`: whole lines are
    /// serialized against each other and against the control replies `next`
    /// writes.
    pub fn send(client: *Client, text: []const u8) WriteError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
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
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        const w = try client.stdin();
        try writeCommandMessage(w, name, arguments);
        try finishLine(w);
    }

    /// Asks the CLI to abandon the turn in progress. The CLI's answer arrives
    /// on the control channel; a refusal surfaces from `next` as
    /// `error.ControlRequestRejected`. Safe from any thread, which is the
    /// point: abandoning an in-flight turn means calling this while another
    /// thread sits in `next`.
    pub fn interrupt(client: *Client) WriteError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        _ = try client.stdin();
        var id_buf: [32]u8 = undefined;
        const request_id = client.nextRequestId(&id_buf);
        try client.writeLineLocked(protocol.writeInterrupt, .{request_id});
    }

    /// Reads the next conversation event. Returns null at end of stream. The
    /// caller owns the returned event.
    ///
    /// Control traffic is serviced here rather than surfaced: when the CLI
    /// asks this process to run one of its `sdk_mcp_servers` tools, or to
    /// answer a permission prompt, the request is dispatched and answered
    /// before this returns, so a handler runs on the caller's thread between
    /// two conversation events.
    ///
    /// That reply needs the write side, so a control request arriving after
    /// `closeStdin` returns `error.StdinClosed` rather than being dropped.
    /// Reading after closing stdin is otherwise normal.
    ///
    /// Draining to null before reaping is the intended flow, but calling this
    /// after `wait` or `kill` is legal and reports a clean end of stream:
    /// once the child is reaped only the exit status remains meaningful, so
    /// anything still buffered is dropped rather than handed out.
    ///
    /// Single consumer. Concurrent calls serialize rather than corrupt, but
    /// the lock is not reentrant, so a handler must not call this. A `kill`
    /// or `wait` on another thread while this one is blocked reading is fine:
    /// the descriptor stays open until `close`, and the child dying is what
    /// ends the read.
    pub fn next(client: *Client) ReadError!?Event {
        client.read_mutex.lockUncancelable(client.io);
        defer client.read_mutex.unlock(client.io);
        if (client.stdoutClosed()) return null;

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
            // Read without the state lock: `next` is the only writer, and
            // this thread is inside `next`.
            if (client.session_id == null) {
                if (event.sessionId()) |id| {
                    // The tree owns the borrowed `id`, so it has to outlive the
                    // dupe, and has to be freed if the dupe is what fails.
                    errdefer event.deinit();
                    const copy = try client.gpa.dupe(u8, id);
                    client.state_mutex.lockUncancelable(client.io);
                    client.session_id = copy;
                    client.state_mutex.unlock(client.io);
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
                        // Kept distinct from a dead child: this one says the
                        // write side was shut by this process while the CLI
                        // still had work to hand back, so the session cannot
                        // service tools any more and only a new one will.
                        error.StdinClosed => return error.StdinClosed,
                        else => return error.WriteFailed,
                    };
                },
                // The CLI answering a request this client sent. A success has
                // nothing to hand back; an error is reported, since the
                // request it refuses is what the caller configured.
                .control_response => {
                    defer event.deinit();
                    try client.noteControlResponse(event.parsed.value);
                },
                else => return event,
            }
        }
    }

    // --- writing ---

    /// Mints the next `zig_N` id and remembers it as awaiting an answer, so
    /// `noteControlResponse` can tell the CLI's reply to it from an echo of
    /// something else. Fixed storage, dropping the oldest when full: an
    /// answer that never comes should not cost the session anything.
    ///
    /// Caller holds `write_mutex`.
    fn nextRequestId(client: *Client, buf: []u8) []const u8 {
        client.next_request_id += 1;
        if (client.pending_len == max_pending_requests) {
            std.mem.copyForwards(u64, client.pending_requests[0 .. max_pending_requests - 1], client.pending_requests[1..]);
            client.pending_len -= 1;
        }
        client.pending_requests[client.pending_len] = client.next_request_id;
        client.pending_len += 1;
        return std.fmt.bufPrint(buf, "zig_{d}", .{client.next_request_id}) catch unreachable;
    }

    /// Terminates and flushes one protocol line. The format is newline
    /// delimited, and the CLI acts on a line only once it lands.
    fn finishLine(w: *Io.Writer) WriteError!void {
        try w.writeByte('\n');
        try w.flush();
    }

    /// Where replies go. Normally the child's stdin; tests point it at a
    /// buffer to read back what the dispatch answered.
    ///
    /// Guarded like `stdin`: `Io.File.Writer` holds the file by value, so after
    /// `closeStdin` the writer points at a descriptor this process no longer
    /// owns, and a recycled fd number would take the write silently.
    ///
    /// Surfaces from `next` as `error.StdinClosed` rather than being dropped,
    /// which tells the caller the session can no longer serve tools — distinct
    /// from `error.WriteFailed`, meaning the child died.
    ///
    /// Caller holds `write_mutex`.
    fn replyWriter(client: *Client) WriteError!*Io.Writer {
        if (builtin.is_test) {
            if (client.reply_override) |w| return w;
        }
        if (client.stdin_closed) return error.StdinClosed;
        return &client.stdin_writer.interface;
    }

    /// Writes one line by handing a `Stringify` over stdin to `f`, holding the
    /// write lock for the line and its flush.
    fn writeLine(client: *Client, comptime f: anytype, args: anytype) WriteError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        try client.writeLineLocked(f, args);
    }

    /// `writeLine` for a caller already holding `write_mutex`.
    fn writeLineLocked(client: *Client, comptime f: anytype, args: anytype) WriteError!void {
        const w = try client.replyWriter();
        var js: std.json.Stringify = .{ .writer = w };
        try @call(.auto, f, .{&js} ++ args);
        try finishLine(w);
    }

    /// Renders one line, newline included, into the scratch arena and hands
    /// it back to be measured. Rendering can only fail for want of memory:
    /// the arena-backed writer has no other failure, and it reports that one
    /// as `WriteFailed`, which is translated here so it does not read as a
    /// dead child upstream.
    fn renderLine(client: *Client, comptime f: anytype, args: anytype) Allocator.Error![]const u8 {
        var out: Io.Writer.Allocating = .init(client.scratch.allocator());
        var js: std.json.Stringify = .{ .writer = &out.writer };
        @call(.auto, f, .{&js} ++ args) catch return error.OutOfMemory;
        out.writer.writeByte('\n') catch return error.OutOfMemory;
        return out.written();
    }

    /// Writes an already rendered and terminated line, under the write lock.
    fn writeRendered(client: *Client, line: []const u8) WriteError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        const w = try client.replyWriter();
        try w.writeAll(line);
        try w.flush();
    }

    /// Runs inside `open`, before the client is handed out, so `closeStdin`
    /// cannot have run and `replyWriter`'s guard cannot fire. The error is
    /// narrowed here rather than widened into `OpenError`, which would put an
    /// unreachable `StdinClosed` on the public spawn path.
    fn sendInitialize(client: *Client) Io.Writer.Error!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        var id_buf: [32]u8 = undefined;
        const request_id = client.nextRequestId(&id_buf);
        client.writeLineLocked(protocol.writeInitialize, .{ request_id, client.servers, client.skills }) catch |err| switch (err) {
            error.StdinClosed => unreachable,
            else => |e| return e,
        };
    }

    fn sendMcpResult(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        result_json: []const u8,
    ) WriteError!void {
        try client.writeLine(protocol.writeMcpResult, .{ request_id, message_id, result_json });
    }

    fn sendMcpError(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        code: i32,
        message: []const u8,
    ) WriteError!void {
        try client.writeLine(protocol.writeMcpError, .{ request_id, message_id, code, message });
    }

    fn sendControlError(client: *Client, request_id: []const u8, message: []const u8) WriteError!void {
        try client.writeLine(protocol.writeControlError, .{ request_id, message });
    }

    fn sendPermissionDeny(client: *Client, request_id: []const u8, message: []const u8) WriteError!void {
        try client.writeLine(protocol.writePermissionDeny, .{ request_id, message });
    }

    /// Renders one of `protocol.results` and sends it as the payload of an MCP
    /// success reply, unless the whole line would overfill the pipe.
    ///
    /// The line is measured after rendering, which is the backstop for
    /// `max_tool_result_bytes`: the caller's check counts raw text, but JSON
    /// escaping can expand a byte up to sixfold as `\uXXXX`, and the envelope
    /// carries ids the CLI sized. An over-long line is replaced rather than
    /// failed, so the request still gets an answer — and one shaped for its
    /// method. A `tools/call` becomes an `is_error` result the model can act
    /// on. An `initialize` or `tools/list` has no such shape, and a `toolCall`
    /// body there would register nothing and say nothing, so those get a
    /// JSON-RPC error naming the size and the bound.
    fn sendMcpResultBody(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        method: []const u8,
        comptime f: anytype,
        args: anytype,
    ) (WriteError || Allocator.Error)!void {
        var body: Io.Writer.Allocating = .init(client.scratch.allocator());
        var js: std.json.Stringify = .{ .writer = &body.writer };
        @call(.auto, f, .{&js} ++ args) catch return error.OutOfMemory;

        const line = try client.renderLine(protocol.writeMcpResult, .{ request_id, message_id, body.written() });
        if (line.len <= max_reply_line_bytes) return client.writeRendered(line);

        if (std.mem.eql(u8, method, "tools/call")) {
            var small: Io.Writer.Allocating = .init(client.scratch.allocator());
            var small_js: std.json.Stringify = .{ .writer = &small.writer };
            protocol.results.toolCall(&small_js, .{
                .text = tool_result_too_long_message,
                .is_error = true,
            }) catch return error.OutOfMemory;
            return client.sendMcpResult(request_id, message_id, small.written());
        }

        const message = try std.fmt.allocPrint(
            client.scratch.allocator(),
            "{s} result too large: the reply line is {d} bytes and the SDK bound is {d} bytes. " ++
                "Register fewer tools, or shorten their names, descriptions and schemas.",
            .{ method, line.len, max_reply_line_bytes },
        );
        return client.sendMcpError(request_id, message_id, -32603, message);
    }

    /// Answers a permission prompt. Bounded like a tool result, since the
    /// reply carries the tool input back and that is as large as the CLI made
    /// it; a decision that does not fit becomes a deny that says so, which
    /// the model can act on, rather than a write that never completes.
    fn sendPermissionDecision(
        client: *Client,
        request_id: []const u8,
        input: std.json.Value,
        decision: PermissionDecision,
    ) (WriteError || Allocator.Error)!void {
        const reply: protocol.PermissionInput = switch (decision) {
            .deny => |message| return client.sendPermissionDeny(request_id, message),
            .allow => .{ .value = input },
            .allow_with_input => |raw| blk: {
                // Spliced raw, so it is checked first: a malformed value would
                // not be a bad reply but a corrupted frame, and the CLI would
                // stall on it until its own timeout.
                if (!try isJsonObject(client.scratch.allocator(), raw)) {
                    return client.sendPermissionDeny(
                        request_id,
                        "permission handler returned an updated input that is not a JSON object; the call was denied",
                    );
                }
                break :blk .{ .raw = raw };
            },
        };

        const line = try client.renderLine(protocol.writePermissionAllow, .{ request_id, reply });
        if (line.len <= max_reply_line_bytes) return client.writeRendered(line);

        const message = try std.fmt.allocPrint(
            client.scratch.allocator(),
            "permission reply too large: the tool input renders to a {d} byte line and the SDK bound is {d} bytes, " ++
                "so the call was denied. Retry with a smaller input.",
            .{ line.len, max_reply_line_bytes },
        );
        return client.sendPermissionDeny(request_id, message);
    }

    // --- control dispatch ---

    fn serveControlRequest(client: *Client, root: std.json.Value) (WriteError || Allocator.Error)!void {
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

        if (std.mem.eql(u8, subtype, "can_use_tool")) {
            return client.servePermissionRequest(request_id, req);
        }

        if (!std.mem.eql(u8, subtype, "mcp_message")) {
            // Anything else is not implemented here. Answer rather than leave
            // the CLI blocked for 60 seconds.
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

        client.resetScratch();

        if (std.mem.eql(u8, method, "initialize")) {
            const offered = if (objectField(message, "params")) |params|
                stringField(params, "protocolVersion") orelse protocol.default_protocol_version
            else
                protocol.default_protocol_version;
            return client.sendMcpResultBody(
                request_id,
                message_id,
                method,
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
                method,
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
                return client.sendMcpResultBody(request_id, message_id, method, protocol.results.toolCall, .{
                    ToolResult{ .text = tool_result_too_long_message, .is_error = true },
                });
            }
            return client.sendMcpResultBody(
                request_id,
                message_id,
                method,
                protocol.results.toolCall,
                .{call},
            );
        }

        return client.sendMcpError(request_id, message_id, -32601, "unsupported mcp method");
    }

    /// A `can_use_tool` request: the CLI asking whether Claude may run a tool
    /// that nothing pre-authorized. Only reaches this process when
    /// `Options.permission_handler` routed prompts here, but the check is
    /// repeated rather than assumed, since a CLI flag is not a promise.
    fn servePermissionRequest(
        client: *Client,
        request_id: []const u8,
        req: std.json.Value,
    ) (WriteError || Allocator.Error)!void {
        const handler = client.permission_handler orelse
            return client.sendControlError(request_id, "unsupported control request");
        const tool_name = stringField(req, "tool_name") orelse
            return client.sendControlError(request_id, "missing tool_name");
        // Absent input is handed on as JSON null rather than refused: the
        // handler is the one deciding, and a tool with no input is a real
        // shape, not a malformed request.
        const input = objectField(req, "input") orelse std.json.Value{ .null = {} };

        client.resetScratch();

        // The same split as a tool handler: a domain failure is a decision
        // the model can see, as a deny naming the error, while running out of
        // memory is a host condition that is answered and then propagated.
        const decision = handler(client.permission_context, client.scratch.allocator(), tool_name, input) catch |err| switch (err) {
            error.OutOfMemory => {
                client.sendPermissionDeny(request_id, "out of memory") catch {};
                return error.OutOfMemory;
            },
            else => PermissionDecision{ .deny = @errorName(err) },
        };
        return client.sendPermissionDecision(request_id, input, decision);
    }

    /// Reset before a handler runs, not after. The rendered reply lives in
    /// this arena and has to stay valid until it is written, so resetting
    /// afterwards would either free it too early or need a second arena.
    /// Resetting on the way in bounds the memory just as well, since the
    /// reply is only ever one dispatch old. `tool.zig` documents the contract
    /// to match. Capacity is kept up to `retain_bytes` so the usual small
    /// dispatch costs no allocation, and released past it so one large reply
    /// does not pin its size for the session.
    fn resetScratch(client: *Client) void {
        _ = client.scratch.reset(.{ .retain_with_limit = retain_bytes });
    }

    /// A `control_response` is the CLI answering one of this client's own
    /// requests. A success carries nothing the caller needs. An error does:
    /// the CLI refusing `initialize` — an `sdkMcpServers` entry it will not
    /// take, say — leaves the session without tools, and the first symptom
    /// otherwise would be the model reporting it cannot find one. Only
    /// answers to ids this client minted count; anything else on the channel
    /// is not addressed here and is left alone.
    fn noteControlResponse(client: *Client, root: std.json.Value) ReadError!void {
        const response = objectField(root, "response") orelse return;
        const request_id = stringField(response, "request_id") orelse return;
        const number = ownRequestNumber(request_id) orelse return;
        // The pending list is write-side state: `interrupt` on another
        // thread may be appending to it.
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        const index = std.mem.indexOfScalar(u64, client.pending_requests[0..client.pending_len], number) orelse return;
        std.mem.copyForwards(
            u64,
            client.pending_requests[index .. client.pending_len - 1],
            client.pending_requests[index + 1 .. client.pending_len],
        );
        client.pending_len -= 1;

        const subtype = stringField(response, "subtype") orelse return;
        if (!std.mem.eql(u8, subtype, "error")) return;

        // Copied before the event is freed by the caller. The CLI puts the
        // text under `error`, the same place this client puts its own.
        const text = stringField(response, "error") orelse "(no error text)";
        const copy = try client.gpa.dupe(u8, text);
        if (client.control_error) |old| client.gpa.free(old);
        client.control_error = copy;
        return error.ControlRequestRejected;
    }

    // --- reading ---

    fn stdoutClosed(client: *Client) bool {
        client.state_mutex.lockUncancelable(client.io);
        defer client.state_mutex.unlock(client.io);
        return client.stdout_closed;
    }

    /// The raw line, valid until the next call.
    fn nextLine(client: *Client) ReadError!?[]const u8 {
        // Released here rather than after the read, since the previous line
        // has to stay readable through `lastLine` until this call. Only past
        // `retain_bytes`: below it the buffer keeps its capacity and the usual
        // small line costs no allocation.
        if (client.line.writer.buffer.len > retain_bytes) {
            client.line.deinit();
            client.line = .init(client.gpa);
        }
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

/// The N of a `zig_N` id this client minted, or null for any other string.
fn ownRequestNumber(request_id: []const u8) ?u64 {
    const prefix = "zig_";
    if (!std.mem.startsWith(u8, request_id, prefix)) return null;
    return std.fmt.parseInt(u64, request_id[prefix.len..], 10) catch null;
}

/// Whether `text` is well-formed JSON whose top-level value is an object.
/// `std.json.validate` accepts any value, and a schema or a tool input that
/// is a string or an array is still valid JSON, so the first byte is checked
/// too. `allocator` backs the scanner's nesting stack only.
fn isJsonObject(allocator: Allocator, text: []const u8) Allocator.Error!bool {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return false;
    return std.json.validate(allocator, trimmed);
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

// Each test below drives one of `readLine`, `writeCommandMessage`,
// `serveControlRequest`, or `noteControlResponse` — all private — and the
// fixtures reach the test-only `reply_override` field, so moving them would
// mean making internals public. The public shape of `Client` is covered from
// tests/client_test.zig.

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

test "the line buffer keeps what readLine last produced" {
    // `lastLine` reads the buffer back, so the raw bytes have to survive both
    // outcomes: the prefix of a line that was cut off, and a line that is not
    // JSON at all, which `readLine` does not know or care about.
    var r: Io.Reader = .fixed("xxxxxxxxxxxxxxxxxxxx\nnot json\n");
    var line: Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();

    try std.testing.expectError(error.ProtocolTooLong, readLine(&r, &line, 8));
    // The prefix that fit: the budget is N+1, so nine bytes were kept.
    try std.testing.expectEqualStrings("xxxxxxxxx", line.written());

    try std.testing.expectEqualStrings("not json", (try readLine(&r, &line, 8)).?);
    try std.testing.expectEqualStrings("not json", line.written());
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
/// reaches the child or the reader.
fn dispatchFixture(out: *Io.Writer.Allocating, servers: []const McpServer) Client {
    var client: Client = undefined;
    // The locks and the `Io` they park on are live even in a fixture that
    // never reaches the child: every write path takes `write_mutex`.
    client.io = std.testing.io;
    client.write_mutex = .init;
    client.read_mutex = .init;
    client.state_mutex = .init;
    client.gpa = std.testing.allocator;
    client.scratch = .init(std.testing.allocator);
    client.servers = servers;
    client.permission_handler = null;
    client.permission_context = null;
    client.pending_len = 0;
    client.control_error = null;
    client.stdin_closed = false;
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

/// Fails unless the reply is a single terminated line that parses as JSON,
/// and hands the tree back for shape checks.
fn parseReply(out: *Io.Writer.Allocating) !std.json.Parsed(std.json.Value) {
    const written = out.written();
    try std.testing.expect(written.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), written[written.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, written[0 .. written.len - 1], '\n') == null);
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, written, .{});
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
        // A permission prompt with no handler installed to answer it.
        \\{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool"}}
        ,
        // Older shape: the id is nested inside `request` rather than beside it.
        \\{"type":"control_request","request":{"request_id":"r4"}}
        ,
        // A subtype this client does not implement at all.
        \\{"type":"control_request","request_id":"r5","request":{"subtype":"hook_callback"}}
        ,
    };

    for (cases, [_][]const u8{ "r1", "r2", "r3", "r4", "r5" }) |line, id| {
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
        \\{"type":"control_request","request_id":7,"request":{"subtype":"hook_callback"}}
        ,
        \\{"type":"control_request","request":{"request_id":7,"subtype":"hook_callback"}}
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
        \\{"type":"control_request","request_id":-9223372036854775808,"request":{"subtype":"hook_callback"}}
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "\"request_id\":\"-9223372036854775808\"",
    ) != null);
}

/// A handler that is never called: the handshake tests only list tools.
fn unreachableHandler(_: ?*anyopaque, _: Allocator, _: std.json.Value) anyerror!ToolResult {
    return error.NotCalled;
}

/// The handshake dispatch is exercised against one server with two tools,
/// one of them carrying a schema, so both the names and the splice show up.
const handshake_tools = [_]tool_mod.Tool{
    .{ .name = "add", .description = "Add.", .handler = unreachableHandler },
    .{
        .name = "env",
        .description = "Env.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}}}",
        .handler = unreachableHandler,
    },
};
const handshake_server: McpServer = .{ .name = "host", .version = "3.2.1", .tools = &handshake_tools };

/// The `mcp_response.result` of a success reply, the part the CLI hands to
/// its MCP client.
fn mcpResult(root: std.json.Value) ?std.json.Value {
    const response = objectField(root, "response") orelse return null;
    const inner = objectField(response, "response") orelse return null;
    const mcp = objectField(inner, "mcp_response") orelse return null;
    return objectField(mcp, "result");
}

test "initialize echoes the offered protocol version through the dispatch" {
    // The renderer is tested in protocol.zig; this pins that the dispatch
    // finds `params.protocolVersion` and hands it through, since the CLI drops
    // the connection on a mismatch.
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{handshake_server},
        \\{"type":"control_request","request_id":"h1","request":{"subtype":"mcp_message","server_name":"host","message":{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2031-04-05","capabilities":{}}}}}
    );
    const parsed = try parseReply(&out);
    defer parsed.deinit();

    const result = mcpResult(parsed.value).?;
    try std.testing.expectEqualStrings("2031-04-05", stringField(result, "protocolVersion").?);
    const info = objectField(result, "serverInfo").?;
    try std.testing.expectEqualStrings("host", stringField(info, "name").?);
    try std.testing.expectEqualStrings("3.2.1", stringField(info, "version").?);
    // Addressed to the request, under the message id the CLI used.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"request_id\":\"h1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":0") != null);
}

test "initialize falls back to the default protocol version" {
    // Both absences: no `protocolVersion` in params, and no params at all.
    const cases = [_][]const u8{
        \\{"type":"control_request","request_id":"h2","request":{"subtype":"mcp_message","server_name":"host","message":{"id":0,"method":"initialize","params":{"capabilities":{}}}}}
        ,
        \\{"type":"control_request","request_id":"h3","request":{"subtype":"mcp_message","server_name":"host","message":{"id":0,"method":"initialize"}}}
        ,
    };
    for (cases) |line| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try dispatch(&out, &.{handshake_server}, line);
        const parsed = try parseReply(&out);
        defer parsed.deinit();
        try std.testing.expectEqualStrings(
            protocol.default_protocol_version,
            stringField(mcpResult(parsed.value).?, "protocolVersion").?,
        );
    }
}

test "a notification is answered with an empty result under id 0" {
    // The notification itself carries no id, but the CLI still waits for an
    // `mcp_response` on the control request and matches it under 0.
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{handshake_server},
        \\{"type":"control_request","request_id":"h4","request":{"subtype":"mcp_message","server_name":"host","message":{"jsonrpc":"2.0","method":"notifications/initialized"}}}
    );
    const parsed = try parseReply(&out);
    defer parsed.deinit();

    const result = mcpResult(parsed.value).?;
    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 0), result.object.count());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"request_id\":\"h4\"") != null);
}

test "tools/list carries every tool name and splices the schemas" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{handshake_server},
        \\{"type":"control_request","request_id":"h5","request":{"subtype":"mcp_message","server_name":"host","message":{"jsonrpc":"2.0","id":1,"method":"tools/list"}}}
    );
    const parsed = try parseReply(&out);
    defer parsed.deinit();

    const tools = objectField(mcpResult(parsed.value).?, "tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("add", stringField(tools[0], "name").?);
    try std.testing.expectEqualStrings("env", stringField(tools[1], "name").?);
    // Spliced as an object, not re-encoded as a string: the parse above only
    // succeeds if the raw schema landed inside the frame intact.
    const schema = objectField(tools[1], "inputSchema").?;
    try std.testing.expectEqualStrings("object", stringField(schema, "type").?);
    try std.testing.expect(objectField(objectField(schema, "properties").?, "name") != null);
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
    // See `max_tool_result_bytes`: an oversized reply deadlocks both processes
    // rather than failing.
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
    // Delivered whole. Measured as the longest unbroken run of filler rather
    // than a total, since `x` also occurs in the surrounding envelope.
    var longest: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, out.written(), i, 'x')) |start| {
        const end = std.mem.indexOfNonePos(u8, out.written(), start, "x") orelse out.written().len;
        longest = @max(longest, end - start);
        i = end;
    }
    try std.testing.expectEqual(max_tool_result_bytes, longest);
    // And still one pipe-load, so the write cannot block.
    try std.testing.expect(out.written().len <= max_reply_line_bytes);
}

test "the bound is measured on the whole line, envelope included" {
    // A result that passes the raw-text check can still overfill the pipe
    // once the envelope is around it. Here the text is just under the cap and
    // the escaping is what tips the rendered line over: every byte is a
    // quote, which renders as two.
    const server: McpServer = .{
        .name = "s",
        .tools = &.{.{ .name = "t", .description = "d", .handler = quoteHandler }},
    };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{server},
        \\{"type":"control_request","request_id":"r","request":{"subtype":"mcp_message","server_name":"s","message":{"method":"tools/call","id":1,"params":{"name":"t"}}}}
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tool result too long") != null);
    try std.testing.expect(out.written().len <= max_reply_line_bytes);
}

/// A result of exactly the cap that doubles when escaped.
fn quoteHandler(_: ?*anyopaque, arena: Allocator, _: std.json.Value) anyerror!ToolResult {
    const text = try arena.alloc(u8, max_tool_result_bytes);
    @memset(text, '"');
    return .{ .text = text };
}

/// Enough tools with 1 KiB schemas to push a `tools/list` reply past the
/// bound, each schema still a valid object so `open` would accept them.
const wide_schema = "{\"type\":\"object\",\"properties\":{\"p\":{\"type\":\"string\",\"description\":\"" ++
    ("x" ** 960) ++ "\"}}}";
const many_tools = blk: {
    var tools: [20]tool_mod.Tool = undefined;
    for (&tools, 0..) |*t, i| {
        t.* = .{
            .name = std.fmt.comptimePrint("tool_{d}", .{i}),
            .description = "d",
            .input_schema = wide_schema,
            .handler = unreachableHandler,
        };
    }
    break :blk tools;
};

test "an oversized tools/list gets a jsonrpc error, not a toolCall body" {
    // A `toolCall` body where the CLI expects `{"tools":[...]}` registers
    // nothing and explains nothing: the model just cannot find the tools. A
    // JSON-RPC error is the shape the method has for failure, and it names
    // the size so the fix is visible.
    const server: McpServer = .{ .name = "host", .tools = &many_tools };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{server},
        \\{"type":"control_request","request_id":"big","request":{"subtype":"mcp_message","server_name":"host","message":{"id":1,"method":"tools/list"}}}
    );
    const parsed = try parseReply(&out);
    defer parsed.deinit();

    try std.testing.expect(mcpResult(parsed.value) == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"tools\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"content\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tools/list result too large") != null);
    const bound = try std.fmt.allocPrint(std.testing.allocator, "{d} bytes", .{max_reply_line_bytes});
    defer std.testing.allocator.free(bound);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), bound) != null);
    try std.testing.expect(out.written().len <= max_reply_line_bytes);
}

test "an oversized initialize gets a jsonrpc error too" {
    // Only the server's own name and version can inflate this one, so the
    // name is what is inflated.
    const server: McpServer = .{ .name = "n" ** (max_reply_line_bytes + 1) };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{server},
        \\{"type":"control_request","request_id":"big","request":{"subtype":"mcp_message","server_name":"
    ++ ("n" ** (max_reply_line_bytes + 1)) ++
        \\","message":{"id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}}}
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "initialize result too large") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"protocolVersion\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"content\"") == null);
}

/// A handler that always fails the way a host running out of memory does.
fn oomHandler(_: ?*anyopaque, _: Allocator, _: std.json.Value) anyerror!ToolResult {
    return error.OutOfMemory;
}

test "a handler that runs out of memory still answers the CLI" {
    // OutOfMemory reaches the caller, but the CLI still has to be answered or
    // it stalls until its own timeout.
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

// --- permission prompts ---

/// What a permission test's handler saw and what it should answer with.
/// What it saw is copied out, since the arena and the parsed request are both
/// gone by the time the test reads it back.
const PermissionProbe = struct {
    decision: PermissionDecision,
    fail: bool = false,
    called: bool = false,
    tool_buf: [32]u8 = undefined,
    tool_len: usize = 0,
    command_buf: [32]u8 = undefined,
    command_len: usize = 0,
    input_was_null: bool = false,

    fn tool(probe: *const PermissionProbe) []const u8 {
        return probe.tool_buf[0..probe.tool_len];
    }

    fn command(probe: *const PermissionProbe) []const u8 {
        return probe.command_buf[0..probe.command_len];
    }
};

fn probeHandler(context: ?*anyopaque, arena: Allocator, tool_name: []const u8, input: std.json.Value) anyerror!PermissionDecision {
    const probe: *PermissionProbe = @ptrCast(@alignCast(context.?));
    probe.called = true;
    probe.tool_len = @min(tool_name.len, probe.tool_buf.len);
    @memcpy(probe.tool_buf[0..probe.tool_len], tool_name[0..probe.tool_len]);
    probe.input_was_null = input == .null;
    if (stringField(input, "command")) |c| {
        probe.command_len = @min(c.len, probe.command_buf.len);
        @memcpy(probe.command_buf[0..probe.command_len], c[0..probe.command_len]);
    }
    // The arena is usable, which is the contract a deny message relies on.
    _ = try arena.alloc(u8, 1);
    if (probe.fail) return error.HostRefused;
    return probe.decision;
}

/// Runs one `can_use_tool` through the dispatch with `probe` installed.
fn dispatchPermission(out: *Io.Writer.Allocating, probe: *PermissionProbe, line: []const u8) !void {
    var client = dispatchFixture(out, &.{});
    defer client.scratch.deinit();
    client.permission_handler = probeHandler;
    client.permission_context = probe;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try client.serveControlRequest(parsed.value);
}

const bash_prompt =
    \\{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls -la","timeout":5}}}
;

/// The `response.response` object of a permission reply.
fn permissionReply(root: std.json.Value) ?std.json.Value {
    const response = objectField(root, "response") orelse return null;
    return objectField(response, "response");
}

test "a permission allow echoes the proposed input back" {
    var probe: PermissionProbe = .{ .decision = .allow };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchPermission(&out, &probe, bash_prompt);

    // The handler saw the real call.
    try std.testing.expectEqualStrings("Bash", probe.tool());
    try std.testing.expectEqualStrings("ls -la", probe.command());

    const parsed = try parseReply(&out);
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"subtype\":\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"request_id\":\"p1\"") != null);
    const reply = permissionReply(parsed.value).?;
    try std.testing.expectEqualStrings("allow", stringField(reply, "behavior").?);
    // The CLI runs the tool with `updatedInput`, so it is always present.
    const updated = objectField(reply, "updatedInput").?;
    try std.testing.expectEqualStrings("ls -la", stringField(updated, "command").?);
    try std.testing.expectEqual(@as(i64, 5), objectField(updated, "timeout").?.integer);
}

test "a permission allow_with_input replaces the input" {
    var probe: PermissionProbe = .{ .decision = .{ .allow_with_input = "{\"command\":\"ls\"}" } };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchPermission(&out, &probe, bash_prompt);

    const parsed = try parseReply(&out);
    defer parsed.deinit();
    const reply = permissionReply(parsed.value).?;
    try std.testing.expectEqualStrings("allow", stringField(reply, "behavior").?);
    const updated = objectField(reply, "updatedInput").?;
    try std.testing.expectEqualStrings("ls", stringField(updated, "command").?);
    // Replaced, not merged: the original's other field is gone.
    try std.testing.expect(objectField(updated, "timeout") == null);
}

test "a permission allow_with_input that is not an object becomes a deny" {
    // It is spliced raw, so anything else would corrupt the frame rather than
    // produce a bad reply. Both a non-object and non-JSON are refused.
    for ([_][]const u8{ "\"ls\"", "{\"command\":", "[]" }) |raw| {
        var probe: PermissionProbe = .{ .decision = .{ .allow_with_input = raw } };
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try dispatchPermission(&out, &probe, bash_prompt);

        const parsed = try parseReply(&out);
        defer parsed.deinit();
        const reply = permissionReply(parsed.value).?;
        try std.testing.expectEqualStrings("deny", stringField(reply, "behavior").?);
        try std.testing.expect(std.mem.indexOf(u8, stringField(reply, "message").?, "not a JSON object") != null);
    }
}

test "a permission deny carries the handler's message" {
    var probe: PermissionProbe = .{ .decision = .{ .deny = "shell is off on this host" } };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchPermission(&out, &probe, bash_prompt);

    const parsed = try parseReply(&out);
    defer parsed.deinit();
    const reply = permissionReply(parsed.value).?;
    try std.testing.expectEqualStrings("deny", stringField(reply, "behavior").?);
    try std.testing.expectEqualStrings("shell is off on this host", stringField(reply, "message").?);
    try std.testing.expect(objectField(reply, "updatedInput") == null);
}

test "a permission handler error becomes a deny naming the error" {
    var probe: PermissionProbe = .{ .decision = .allow, .fail = true };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchPermission(&out, &probe, bash_prompt);

    const parsed = try parseReply(&out);
    defer parsed.deinit();
    const reply = permissionReply(parsed.value).?;
    try std.testing.expectEqualStrings("deny", stringField(reply, "behavior").?);
    try std.testing.expectEqualStrings("HostRefused", stringField(reply, "message").?);
}

test "a permission prompt without a tool_name is answered with an error" {
    // Nothing to decide about, but still something to answer, or the CLI
    // waits out its timeout.
    var probe: PermissionProbe = .{ .decision = .allow };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchPermission(&out, &probe,
        \\{"type":"control_request","request_id":"p2","request":{"subtype":"can_use_tool","input":{}}}
    );
    try std.testing.expect(!probe.called);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"subtype\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "missing tool_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"request_id\":\"p2\"") != null);
}

test "a permission prompt without input hands the handler null" {
    var probe: PermissionProbe = .{ .decision = .allow };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchPermission(&out, &probe,
        \\{"type":"control_request","request_id":"p3","request":{"subtype":"can_use_tool","tool_name":"Glob"}}
    );
    try std.testing.expect(probe.called);
    try std.testing.expect(probe.input_was_null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"updatedInput\":null") != null);
}

test "an oversized permission reply becomes a deny that says why" {
    // The reply carries the input back, so the bound applies to it like a
    // tool result. A deny the model can read beats a write that blocks.
    const big = "{\"command\":\"" ++ ("y" ** (max_reply_line_bytes + 1)) ++ "\"}";
    var probe: PermissionProbe = .{ .decision = .{ .allow_with_input = big } };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchPermission(&out, &probe, bash_prompt);

    const parsed = try parseReply(&out);
    defer parsed.deinit();
    const reply = permissionReply(parsed.value).?;
    try std.testing.expectEqualStrings("deny", stringField(reply, "behavior").?);
    try std.testing.expect(std.mem.indexOf(u8, stringField(reply, "message").?, "too large") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "yyyyyyyy") == null);
    try std.testing.expect(out.written().len <= max_reply_line_bytes);
}

// --- control responses ---

/// A client with just the fields `noteControlResponse` touches.
fn responseFixture() Client {
    var client: Client = undefined;
    // The locks and the `Io` they park on are live even in a fixture that
    // never reaches the child: every write path takes `write_mutex`.
    client.io = std.testing.io;
    client.write_mutex = .init;
    client.read_mutex = .init;
    client.state_mutex = .init;
    client.gpa = std.testing.allocator;
    client.next_request_id = 0;
    client.pending_len = 0;
    client.control_error = null;
    return client;
}

fn noteResponse(client: *Client, line: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try client.noteControlResponse(parsed.value);
}

test "an error response to this client's own request is reported" {
    var client = responseFixture();
    defer if (client.control_error) |text| std.testing.allocator.free(text);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("zig_1", client.nextRequestId(&buf));
    try std.testing.expectEqual(@as(usize, 1), client.pending_len);

    try std.testing.expectError(error.ControlRequestRejected, noteResponse(&client,
        \\{"type":"control_response","response":{"subtype":"error","request_id":"zig_1","error":"sdkMcpServers rejected"}}
    ));
    try std.testing.expectEqualStrings("sdkMcpServers rejected", client.lastControlError().?);
    // Answered, so no longer pending.
    try std.testing.expectEqual(@as(usize, 0), client.pending_len);

    // A later error replaces the text rather than leaking the first.
    _ = client.nextRequestId(&buf);
    try std.testing.expectError(error.ControlRequestRejected, noteResponse(&client,
        \\{"type":"control_response","response":{"subtype":"error","request_id":"zig_2"}}
    ));
    try std.testing.expectEqualStrings("(no error text)", client.lastControlError().?);
}

test "a success response is consumed silently" {
    var client = responseFixture();
    var buf: [32]u8 = undefined;
    _ = client.nextRequestId(&buf);
    try noteResponse(&client,
        \\{"type":"control_response","response":{"subtype":"success","request_id":"zig_1","response":{}}}
    );
    try std.testing.expect(client.lastControlError() == null);
    try std.testing.expectEqual(@as(usize, 0), client.pending_len);
}

test "responses to ids this client never sent are left alone" {
    // An error addressed elsewhere, or to a `zig_N` this client did not mint,
    // is not this client's to report: the request it refuses was never made.
    var client = responseFixture();
    var buf: [32]u8 = undefined;
    _ = client.nextRequestId(&buf);
    for ([_][]const u8{
        \\{"type":"control_response","response":{"subtype":"error","request_id":"req_9","error":"x"}}
        ,
        \\{"type":"control_response","response":{"subtype":"error","request_id":"zig_7","error":"x"}}
        ,
        \\{"type":"control_response","response":{"subtype":"error"}}
        ,
        \\{"type":"control_response"}
        ,
    }) |line| try noteResponse(&client, line);
    try std.testing.expect(client.lastControlError() == null);
    // Still waiting on the one that was sent.
    try std.testing.expectEqual(@as(usize, 1), client.pending_len);
}

test "the pending list drops its oldest entry rather than growing" {
    var client = responseFixture();
    var buf: [32]u8 = undefined;
    for (0..max_pending_requests + 3) |_| _ = client.nextRequestId(&buf);
    try std.testing.expectEqual(@as(usize, max_pending_requests), client.pending_len);
    // The oldest three fell off; the newest is still there.
    try std.testing.expectEqual(@as(u64, 4), client.pending_requests[0]);
    try std.testing.expectEqual(@as(u64, max_pending_requests + 3), client.pending_requests[client.pending_len - 1]);
}

// --- live child ---

/// A shell script stood in for the CLI, spawned through the real `open`.
const StubChild = struct {
    dir: std.testing.TmpDir,
    path: [:0]u8,
    threaded: Io.Threaded,

    fn init(script: []const u8) !StubChild {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        try dir.dir.writeFile(std.testing.io, .{
            .sub_path = "stub.sh",
            .data = script,
            .flags = .{ .permissions = .executable_file },
        });
        const path = try dir.dir.realPathFileAlloc(std.testing.io, "stub.sh", std.testing.allocator);
        errdefer std.testing.allocator.free(path);
        return .{ .dir = dir, .path = path, .threaded = .init(std.testing.allocator, .{}) };
    }

    fn deinit(stub: *StubChild) void {
        stub.threaded.deinit();
        std.testing.allocator.free(stub.path);
        stub.dir.cleanup();
    }

    fn open(stub: *StubChild, options: Options) !*Client {
        var o = options;
        o.claude_path = stub.path;
        return Client.open(std.testing.allocator, stub.threaded.io(), o);
    }
};

test "open takes the stdout descriptor out of the Child" {
    // Reaping through the stdlib closes every descriptor the `Child` still
    // holds. The reader keeps its own copy of stdout by value, so a reap on
    // one thread would close the descriptor under a `next` blocked on
    // another, and a recycled number would then be read as the child's
    // stream. `open` moves stdout out of the `Child`; `close` closes it,
    // last, once no reader can be inside `next`.
    var stub = try StubChild.init("#!/bin/sh\nexit 0\n");
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try std.testing.expect(client.child.stdout == null);
    // stdin stays with the `Child` until `closeStdin` takes it.
    try std.testing.expect(client.child.stdin != null);
}

test "open rejects a zero max_line_bytes instead of failing forever" {
    // Zero is a permanent-error trap: no line can ever satisfy it, so the read
    // loop would fail forever. Refused before anything is allocated or spawned.
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

test "open rejects a tool schema that is not a JSON object before spawning" {
    // The schema is spliced into the `tools/list` frame raw, so a bad one is
    // a corrupted handshake rather than a failed call. The path names a
    // binary that does not exist: a spawn attempt would fail with its own
    // error, so getting this one proves the check runs first.
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    for ([_][]const u8{ "not json", "{\"type\":\"object\"", "[]", "\"{}\"", "" }) |schema| {
        const tools = [_]tool_mod.Tool{.{ .name = "t", .description = "d", .input_schema = schema, .handler = unreachableHandler }};
        const servers = [_]McpServer{.{ .name = "s", .tools = &tools }};
        try std.testing.expectError(error.InvalidToolSchema, Client.open(
            std.testing.allocator,
            threaded.io(),
            .{ .claude_path = "/nonexistent/claude", .sdk_mcp_servers = &servers },
        ));
    }

    // Leading whitespace is still an object.
    const tools = [_]tool_mod.Tool{.{ .name = "t", .description = "d", .input_schema = "  {}", .handler = unreachableHandler }};
    const servers = [_]McpServer{.{ .name = "s", .tools = &tools }};
    try std.testing.expectError(error.FileNotFound, Client.open(
        std.testing.allocator,
        threaded.io(),
        .{ .claude_path = "/nonexistent/claude", .sdk_mcp_servers = &servers },
    ));
}

test "killed pairs with term rather than replacing it" {
    // `term` is what the kernel reported, even after a kill; `killed` is the
    // separate fact that this client sent the signal. A child that trapped
    // it and exited cleanly is `killed` with an `.exited` term.
    var client: Client = undefined;
    // The locks and the `Io` they park on are live even in a fixture that
    // never reaches the child: every write path takes `write_mutex`.
    client.io = std.testing.io;
    client.write_mutex = .init;
    client.read_mutex = .init;
    client.state_mutex = .init;
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

test "kill still runs after a failed reap" {
    // A real `kill` against a live child, with `wait_error` pre-set to the
    // state a failed reap leaves behind: the child still live and unreaped,
    // and `term` still null because nothing was observed. A genuine failed
    // reap is not reachable from the public API, so the state is set by hand
    // and `kill`'s effects are what is observed — guarding `kill` on
    // `wait_error` changes only whether the body runs.
    var stub = try StubChild.init("#!/bin/sh\ntrap '' PIPE\nsleep 3\nexit 0\n");
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    client.wait_error = error.Unexpected;
    client.kill();

    // `kill` ran: it signalled, reaped, and recorded what it observed. A
    // `kill` that returned early on `wait_error` leaves both of these unset.
    try std.testing.expect(client.killed);
    try std.testing.expectEqual(std.posix.SIG.TERM, client.term.?.signal);
}

test "a rejected initialize surfaces from next with the CLI's text" {
    // The stub plays a CLI refusing the handshake: `open` sends `zig_1`, the
    // stub answers it with an error, then carries on with a normal line, so
    // the test also shows the stream survives the report.
    var stub = try StubChild.init(
        "#!/bin/sh\n" ++
            "trap '' PIPE\n" ++
            "printf '{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"zig_1\",\"error\":\"sdkMcpServers rejected\"}}\\n'\n" ++
            "printf 'not json\\n'\n" ++
            "printf '{\"type\":\"result\",\"session_id\":\"s\",\"result\":\"ok\"}\\n'\n" ++
            "exit 0\n",
    );
    defer stub.deinit();

    const none: []const []const u8 = &.{};
    const client = try stub.open(.{ .skills = none });
    defer _ = client.close();

    try std.testing.expect(client.lastControlError() == null);
    try std.testing.expectError(error.ControlRequestRejected, client.next());
    try std.testing.expectEqualStrings("sdkMcpServers rejected", client.lastControlError().?);

    // The next line is not JSON, and `lastLine` says exactly what it was.
    try std.testing.expectError(error.InvalidJson, client.next());
    try std.testing.expectEqualStrings("not json", client.lastLine());

    // And the stream is intact past both.
    var event = (try client.next()).?;
    defer event.deinit();
    try std.testing.expectEqual(Kind.result, event.kind);
    try std.testing.expect(std.mem.startsWith(u8, client.lastLine(), "{\"type\":\"result\""));
    try std.testing.expect(try client.next() == null);
    try std.testing.expectEqual(@as(usize, 0), client.lastLine().len);
}

test "a control request arriving after closeStdin is refused, not written blind" {
    // Without `replyWriter`'s `stdin_closed` check the reply goes to a closed
    // descriptor, and lands silently on an unrelated file once the fd number is
    // recycled. No `reply_override` here: it bypasses the very guard under test.
    var client: Client = undefined;
    // The locks and the `Io` they park on are live even in a fixture that
    // never reaches the child: every write path takes `write_mutex`.
    client.io = std.testing.io;
    client.write_mutex = .init;
    client.read_mutex = .init;
    client.state_mutex = .init;
    client.gpa = std.testing.allocator;
    client.scratch = .init(std.testing.allocator);
    defer client.scratch.deinit();
    client.servers = &.{};
    client.permission_handler = null;
    client.reply_override = null;
    client.stdin_closed = true;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"type":"control_request","request_id":"r","request":{"subtype":"hook_callback"}}
    , .{});
    defer parsed.deinit();

    // Refused rather than dropped. Silence would strand the CLI until its own
    // ~60 second timeout, which is what the "every exit past the id answers"
    // invariant exists to prevent.
    try std.testing.expectError(error.StdinClosed, client.serveControlRequest(parsed.value));

    // And it stays distinct from a dead child all the way out through `next`,
    // so the caller can tell "this session can no longer serve tools" from
    // "the write failed".
    const e: ReadError = error.StdinClosed;
    try std.testing.expectEqual(ReadError.StdinClosed, e);
}

// --- fuzz ---

// `std.testing.fuzz` runs each of these over the empty input and the listed
// corpus in an ordinary `zig build test`, and over generated inputs under
// `zig build test --fuzz`. What they pin is the absence of panics and runaway
// loops on bytes this process did not choose, which is the read side's real
// threat model: every line comes from the CLI, and a control request's shape
// is whatever the CLI's release put there. They stay here because `readLine`,
// `serveControlRequest`, and `dispatchFixture` are private.

fn fuzzReadLine(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const input = buf[0..smith.sliceWithHash(&buf, 0x7ead11)];
    // A fixed-width integer, since the fuzz ABI cannot describe `usize`.
    const max_line_bytes: usize = smith.valueRangeAtMostWithHash(u8, 1, 128, 0x7ead12);

    var r: Io.Reader = .fixed(input);
    var line: Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();

    // Every call consumes at least one byte or reports end of stream, so the
    // number of calls is bounded by the input; counting them turns a resync
    // regression into a failure instead of a hang.
    var calls: usize = 0;
    while (true) : (calls += 1) {
        if (calls > input.len + 1) return error.ReadLineDidNotAdvance;
        const got = readLine(&r, &line, max_line_bytes) catch |err| switch (err) {
            error.ProtocolTooLong => continue,
            else => return err,
        };
        const text = got orelse break;
        try std.testing.expect(text.len <= max_line_bytes);
        try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
        // What `next` does with the line: parse it, and report rather than
        // panic when it is not JSON.
        if (std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{})) |parsed| {
            parsed.deinit();
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
    }
}

test "readLine neither panics nor stalls on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzReadLine, .{ .corpus = &.{
        "{\"a\":1}\n{\"b\":2}\n",
        "\n\n\n",
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        "{\"type\":\"result\",\"result\":\"unterminated",
    } });
}

fn fuzzDispatch(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const input = buf[0..smith.sliceWithHash(&buf, 0x7ead21)];

    // A line that is not JSON never reaches the dispatch: `next` reports
    // InvalidJson first. Only parseable input exercises anything here.
    const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var client = dispatchFixture(&out, &.{});
    defer client.scratch.deinit();
    try client.serveControlRequest(parsed.value);

    // The invariant the dispatch promises: silence only when there is no id
    // to answer, and otherwise exactly one newline-terminated line.
    const written = out.written();
    if (written.len > 0) {
        try std.testing.expectEqual(@as(?usize, written.len - 1), std.mem.indexOfScalar(u8, written, '\n'));
    }
}

test "serveControlRequest answers or stays silent on arbitrary JSON, never panics" {
    try std.testing.fuzz({}, fuzzDispatch, .{ .corpus = &.{
        "{\"type\":\"control_request\",\"request_id\":\"r1\"}",
        "{\"type\":\"control_request\",\"request_id\":7,\"request\":{\"subtype\":\"can_use_tool\"}}",
        "{\"type\":\"control_request\",\"request_id\":\"r2\",\"request\":{\"subtype\":\"mcp_message\",\"server_name\":\"s\",\"message\":{\"method\":\"tools/list\",\"id\":1}}}",
        "[1,2,3]",
        "\"just a string\"",
        "{\"request\":{\"request_id\":{\"nested\":true},\"subtype\":\"mcp_message\"}}",
    } });
}
