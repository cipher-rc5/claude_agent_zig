// src/client.zig
// CLI process lifecycle, event streaming, and control dispatch.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const event_mod = @import("event.zig");
const options_mod = @import("options.zig");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
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

/// Maximum tool text before escaping; complete replies have a separate cap.
pub const max_tool_result_bytes: usize = 16 * 1024;

// Reply metadata allowance; the rendered frame also accounts for escaping.
const tool_result_envelope_bytes: usize = 512;

/// Complete reply cap, including newline; fallbacks obey the same bound.
pub const max_reply_line_bytes: usize = max_tool_result_bytes + tool_result_envelope_bytes;

const tool_result_too_long_message =
    "tool result too long: the SDK caps a tool result at 16384 bytes. " ++
    "Return less data, or a reference to it.";

// Release larger scratch and line buffers on their next use.
const retain_bytes: usize = 1024 * 1024;

const max_pending_requests = 16;

pub const OpenError = error{
    /// `Options.max_line_bytes` is zero.
    InvalidMaxLineBytes,
    InvalidWriteTimeout,
    InvalidBufferSize,
    InvalidRegistration,
    TransportFailed,
    WriteTimedOut,
    /// Schema is invalid JSON or not an object; checked before spawning.
    InvalidToolSchema,
} || std.process.SpawnError || Allocator.Error || Io.Writer.Error;

/// Allocation-free write errors, pinned independently of stdlib error sets.
pub const WriteError = error{
    /// Stdin is closed; its descriptor may have been reused.
    StdinClosed,
    WriteFailed,
    WriteTimedOut,
    TransportFailed,
    TooManyPendingRequests,
    ReplyTooLong,
};

pub const ReadError = error{
    ProtocolTooLong,
    ProtocolTooDeep,
    ReadFailed,
    WriteFailed,
    InvalidJson,
    /// A control request requires a reply after stdin has been closed.
    StdinClosed,
    /// The CLI rejected an interrupt; reading may continue.
    ControlRequestRejected,
    /// Initialize was rejected; SDK tools and skill restrictions are unconfigured.
    InitializationRejected,
    WriteTimedOut,
    TransportFailed,
    ReplyTooLong,
} || Allocator.Error;

pub const InitializationState = enum { not_required, pending, accepted, rejected, failed };

pub const Status = struct {
    initialization: InitializationState,
    term: ?std.process.Child.Term,
    killed: bool,
    force_killed: bool,
    stdin_closed: bool,
    transport_failed: bool,
    wait_error: ?std.process.Child.WaitError,
    flush_error: ?Io.Writer.Error,
};

const ProcessAdapter = struct {
    context: *anyopaque,
    poll: *const fn (*anyopaque, *std.process.Child) std.process.Child.WaitError!?std.process.Child.Term,
    signal: *const fn (*anyopaque, std.process.Child.Id, std.posix.SIG) void,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    stdin_buffer: []u8,
    stdout_buffer: []u8,
    stdin_writer: transport.Writer,
    stdout_reader: transport.Reader,
    transport_state: transport.State = .{},
    termination_grace_ms: u32,
    force_killed: bool = false,
    initialization: InitializationState = .not_required,
    initialize_request: ?u64 = null,
    line: Io.Writer.Allocating,
    max_line_bytes: usize,
    servers: []const McpServer,
    /// Borrowed, like `servers`; valid through `close`.
    skills: ?[]const []const u8,
    permission_handler: ?PermissionHandler,
    permission_context: ?*anyopaque,
    scratch: std.heap.ArenaAllocator,
    next_request_id: u64 = 0,
    /// Pending `zig_N` numbers, oldest first.
    pending_requests: [max_pending_requests]u64 = undefined,
    pending_len: usize = 0,
    /// Owned rejection text, exposed by `lastControlError`.
    control_error: ?[]u8 = null,
    session_id: ?[]u8 = null,
    stdin_closed: bool = false,
    /// Reaped or stopped: `next` returns null; the descriptor stays open until `close`.
    stdout_closed: bool = false,
    /// Observed child status. Use `status()` during concurrent operations.
    term: ?std.process.Child.Term = null,
    /// Termination requested; read via `status()` during concurrency.
    killed: bool = false,
    // Test-only process and reply adapters.
    process_override: if (builtin.is_test) ?ProcessAdapter else void = if (builtin.is_test) null else {},
    reply_override: if (builtin.is_test) ?*Io.Writer else void = if (builtin.is_test) null else {},
    /// Reap error, separate from `term`; read via `status()` during concurrency.
    wait_error: ?std.process.Child.WaitError = null,
    /// Final flush error; `wait` and `kill` cannot return write errors.
    flush_error: ?Io.Writer.Error = null,
    /// Lock order is write -> state. State never waits for either I/O lock.
    write_mutex: Io.Mutex = .init,
    /// Serializes parsing and synchronous handlers; handlers must not reenter next.
    read_mutex: Io.Mutex = .init,
    /// Serializes nonblocking reap, signals, and published status.
    state_mutex: Io.Mutex = .init,

    /// Spawns the CLI at a stable address required by its embedded I/O interfaces.
    pub fn open(gpa: Allocator, io: Io, options: Options) OpenError!*Client {
        if (options.max_line_bytes == 0) return error.InvalidMaxLineBytes;
        if (options.write_timeout_ms == 0) return error.InvalidWriteTimeout;
        if (options.stdin_buffer_size == 0 or options.stdout_buffer_size == 0) return error.InvalidBufferSize;
        for (options.sdk_mcp_servers, 0..) |server, si| {
            if (server.name.len == 0) return error.InvalidRegistration;
            for (options.sdk_mcp_servers[0..si]) |prior| {
                if (std.mem.eql(u8, prior.name, server.name)) return error.InvalidRegistration;
            }
            for (server.tools, 0..) |tool, ti| {
                if (tool.name.len == 0) return error.InvalidRegistration;
                for (server.tools[0..ti]) |prior| {
                    if (std.mem.eql(u8, prior.name, tool.name)) return error.InvalidRegistration;
                }
                if (!try isJsonObject(gpa, tool.input_schema)) return error.InvalidToolSchema;
            }
        }

        const client = try gpa.create(Client);
        errdefer gpa.destroy(client);

        const stdin_buffer = try gpa.alloc(u8, options.stdin_buffer_size);
        errdefer gpa.free(stdin_buffer);
        const stdout_buffer = try gpa.alloc(u8, options.stdout_buffer_size);
        errdefer gpa.free(stdout_buffer);

        // `spawn` does not retain argv.
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
        errdefer forceCleanup(&child, io);

        // Retain stdout across reaping; only `close` may release an active reader's fd.
        const stdout_file = child.stdout.?;
        child.stdout = null;
        errdefer stdout_file.close(io);

        try transport.nonblocking(child.stdin.?);
        try transport.nonblocking(stdout_file);

        client.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .stdin_buffer = stdin_buffer,
            .stdout_buffer = stdout_buffer,
            .stdin_writer = transport.Writer.init(child.stdin.?, io, &client.transport_state, stdin_buffer, options.write_timeout_ms),
            .stdout_reader = transport.Reader.init(stdout_file, io, &client.transport_state, stdout_buffer),
            .termination_grace_ms = options.termination_grace_ms,
            .line = .init(gpa),
            .max_line_bytes = options.max_line_bytes,
            .servers = options.sdk_mcp_servers,
            .skills = options.skills,
            .permission_handler = options.permission_handler,
            .permission_context = options.permission_context,
            .scratch = .init(gpa),
        };

        errdefer client.line.deinit();
        errdefer client.scratch.deinit();

        if (options.needsInitialize()) try client.sendInitialize();
        return client;
    }

    /// Closes stdin and waits without a deadline; another thread may terminate the child.
    pub fn wait(client: *Client) std.process.Child.WaitError!std.process.Child.Term {
        client.closeStdin();
        return client.awaitExit(null);
    }

    /// Stops pipe I/O, sends SIGTERM, then escalates after `grace_ms` and reaps.
    /// Cleanup blocks cancellation; only the direct child is signaled.
    /// Host callbacks must return before `close` can free their resources.
    pub fn terminate(client: *Client, grace_ms: u32) std.process.Child.WaitError!std.process.Child.Term {
        const protection = client.io.swapCancelProtection(.blocked);
        defer _ = client.io.swapCancelProtection(protection);
        client.requestSignal(.TERM);
        const deadline = Io.Clock.awake.now(client.io).addDuration(.fromMilliseconds(grace_ms));
        const term = try client.awaitExit(deadline);
        client.closeStdin();
        return term;
    }

    /// Terminates using `Options.termination_grace_ms`. Thread-safe and idempotent.
    pub fn kill(client: *Client) void {
        _ = client.terminate(client.termination_grace_ms) catch {};
    }

    /// Sends SIGKILL without a grace period and reaps the direct child.
    pub fn forceKill(client: *Client) std.process.Child.WaitError!std.process.Child.Term {
        const protection = client.io.swapCancelProtection(.blocked);
        defer _ = client.io.swapCancelProtection(protection);
        client.requestSignal(.KILL);
        const term = try client.awaitExit(null);
        client.closeStdin();
        return term;
    }

    fn requestSignal(client: *Client, signal: std.posix.SIG) void {
        const io = client.io;
        client.state_mutex.lockUncancelable(io);
        defer client.state_mutex.unlock(io);
        if (client.term != null or client.child.id == null) return;
        client.transport_state.stopped.store(true, .release);
        if (client.initialization == .pending) client.initialization = .failed;
        client.stdout_closed = true;
        client.killed = true;
        if (signal == .KILL) client.force_killed = true;
        client.signalProcess(signal);
    }

    fn signalProcess(client: *Client, signal: std.posix.SIG) void {
        if (builtin.is_test) {
            if (client.process_override) |adapter| return adapter.signal(adapter.context, client.child.id.?, signal);
        }
        std.posix.kill(client.child.id.?, signal) catch {};
    }

    fn pollProcess(client: *Client) std.process.Child.WaitError!?std.process.Child.Term {
        if (builtin.is_test) {
            if (client.process_override) |adapter| return adapter.poll(adapter.context, &client.child);
        }
        return transport.pollChild(&client.child);
    }

    fn awaitExit(client: *Client, escalation: ?Io.Timestamp) std.process.Child.WaitError!std.process.Child.Term {
        const io = client.io;
        var deadline = escalation;
        while (true) {
            client.state_mutex.lockUncancelable(io);
            if (client.term) |term| {
                client.state_mutex.unlock(io);
                return term;
            }
            if (client.child.id == null) {
                const err = client.wait_error orelse error.Unexpected;
                client.state_mutex.unlock(io);
                return err;
            }
            // Share the signal lock so reaped PIDs cannot be signaled after reuse.
            const result = client.pollProcess() catch |err| {
                client.wait_error = err;
                client.state_mutex.unlock(io);
                return err;
            };
            if (result) |term| {
                client.term = term;
                if (client.initialization == .pending) client.initialization = .failed;
                client.wait_error = null;
                client.stdout_closed = true;
                client.transport_state.stopped.store(true, .release);
                client.state_mutex.unlock(io);
                return term;
            }
            if (deadline) |limit| {
                if (Io.Clock.awake.now(io).nanoseconds >= limit.nanoseconds) {
                    client.killed = true;
                    client.force_killed = true;
                    client.signalProcess(.KILL);
                    deadline = null;
                }
            }
            client.state_mutex.unlock(io);
            // Canceling a waiter does not release ownership of the child.
            try io.sleep(.fromMilliseconds(2), .awake);
        }
    }

    /// Snapshot safe during reads, writes, waits, and termination.
    pub fn status(client: *Client) Status {
        client.state_mutex.lockUncancelable(client.io);
        defer client.state_mutex.unlock(client.io);
        return .{
            .initialization = client.initialization,
            .term = client.term,
            .killed = client.killed,
            .force_killed = client.force_killed,
            .stdin_closed = client.transport_state.stdin_closed.load(.acquire),
            .transport_failed = client.transport_state.failed.load(.acquire),
            .wait_error = client.wait_error,
            .flush_error = client.flush_error,
        };
    }

    /// Final call: join other client users first. Reaps and frees the client.
    /// Returns `.unknown` on reap failure; use `wait` to receive the error.
    pub fn close(client: *Client) std.process.Child.Term {
        const close_io = client.io;
        const protection = close_io.swapCancelProtection(.blocked);
        defer _ = close_io.swapCancelProtection(protection);
        const term = client.wait() catch client.forceKill() catch blk: {
            client.state_mutex.lockUncancelable(close_io);
            defer client.state_mutex.unlock(close_io);
            forceCleanup(&client.child, close_io);
            client.stdout_closed = true;
            client.transport_state.stopped.store(true, .release);
            break :blk std.process.Child.Term{ .unknown = 0 };
        };
        client.read_mutex.lockUncancelable(client.io);
        client.read_mutex.unlock(client.io);
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

    /// Resume ID set once by `next`; thread-safe and valid until `close`.
    pub fn sessionId(client: *Client) ?[]const u8 {
        client.state_mutex.lockUncancelable(client.io);
        defer client.state_mutex.unlock(client.io);
        return client.session_id;
    }

    /// Last raw line or oversized prefix; empty before reading and at EOF.
    /// Reader-thread only; borrowed until the next `next` call.
    pub fn lastLine(client: *const Client) []const u8 {
        return client.line.writer.buffered();
    }

    /// Last rejection or null; reader-thread only, valid until rejection or `close`.
    pub fn lastControlError(client: *const Client) ?[]const u8 {
        return client.control_error;
    }

    /// Closes stdin even if flushing fails; retains the error in `flush_error`.
    pub fn closeStdin(client: *Client) void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        if (client.stdin_closed) return;
        client.stdin_closed = true;
        client.transport_state.stdin_closed.store(true, .release);
        client.stdin_writer.begin();
        if (!client.transport_state.stopped.load(.acquire) and !client.transport_state.failed.load(.acquire)) {
            client.stdin_writer.interface.flush() catch |err| {
                client.state_mutex.lockUncancelable(client.io);
                client.flush_error = err;
                client.state_mutex.unlock(client.io);
            };
        } else if (client.stdin_writer.interface.end > 0) {
            client.state_mutex.lockUncancelable(client.io);
            client.flush_error = error.WriteFailed;
            client.state_mutex.unlock(client.io);
            client.stdin_writer.interface.end = 0;
        }
        if (client.child.stdin) |file| {
            file.close(client.io);
            client.child.stdin = null;
        }
    }

    // Caller holds `write_mutex`; reject closed or failed transport before I/O.
    fn stdin(client: *Client) WriteError!*Io.Writer {
        if (client.stdin_closed) return error.StdinClosed;
        if (client.transport_state.stopped.load(.acquire) or client.transport_state.failed.load(.acquire)) return error.TransportFailed;
        client.stdin_writer.begin();
        return &client.stdin_writer.interface;
    }

    /// Queues a turn or mid-turn guidance; thread-safe, including from handlers.
    pub fn send(client: *Client, text: []const u8) WriteError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        const w = try client.stdin();
        protocol.writeUserMessage(w, text) catch return client.writeFailure();
        finishLine(w) catch return client.writeFailure();
    }

    /// Sends `/name arguments`, including skills omitted from the session list.
    pub fn sendCommand(client: *Client, name: []const u8, arguments: []const u8) WriteError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        const w = try client.stdin();
        writeCommandMessage(w, name, arguments) catch return client.writeFailure();
        finishLine(w) catch return client.writeFailure();
    }

    /// Thread-safe interruption; CLI refusal surfaces from `next` as `ControlRequestRejected`.
    pub fn interrupt(client: *Client) WriteError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        _ = try client.stdin();
        var id_buf: [32]u8 = undefined;
        const request_id = try client.nextRequestId(&id_buf);
        errdefer client.pending_len -= 1;
        try client.writeLineLocked(protocol.writeInterrupt, .{request_id});
    }

    /// Returns a caller-owned event or null at EOF; release events with `deinit`.
    /// Calls serialize; synchronous handlers must not reenter. Concurrent wait/kill is safe.
    /// Reaping discards buffered output. Replies after stdin closes fail with `StdinClosed`.
    pub fn next(client: *Client) ReadError!?Event {
        client.read_mutex.lockUncancelable(client.io);
        defer client.read_mutex.unlock(client.io);
        if (client.stdoutClosed()) return null;
        if (client.transport_state.failed.load(.acquire)) return error.TransportFailed;

        while (true) {
            const line = (try client.nextLine()) orelse return null;
            if (line.len == 0) continue;
            if (!jsonDepthWithin(line)) {
                client.transport_state.failed.store(true, .release);
                _ = client.forceKill() catch {};
                return error.ProtocolTooDeep;
            }

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
            // `next` is the sole writer and holds `read_mutex`.
            if (client.session_id == null) {
                if (event.sessionId()) |id| {
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
                    client.serveControlRequest(event.parsed.value) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.StdinClosed => return error.StdinClosed,
                        error.WriteTimedOut => return error.WriteTimedOut,
                        error.ReplyTooLong => {
                            _ = client.forceKill() catch {};
                            return error.ReplyTooLong;
                        },
                        error.TransportFailed => return error.TransportFailed,
                        else => return error.WriteFailed,
                    };
                },
                .control_response => {
                    defer event.deinit();
                    try client.noteControlResponse(event.parsed.value);
                },
                else => return event,
            }
        }
    }

    // --- writing ---

    // Caller holds `write_mutex`; failed sends release their reservation.
    fn nextRequestId(client: *Client, buf: []u8) WriteError![]const u8 {
        if (client.pending_len == max_pending_requests or client.next_request_id == std.math.maxInt(u64))
            return error.TooManyPendingRequests;
        client.next_request_id += 1;
        client.pending_requests[client.pending_len] = client.next_request_id;
        client.pending_len += 1;
        return std.fmt.bufPrint(buf, "zig_{d}", .{client.next_request_id}) catch unreachable;
    }

    fn finishLine(w: *Io.Writer) WriteError!void {
        try w.writeByte('\n');
        try w.flush();
    }

    // Caller holds `write_mutex`; test overrides bypass the stdin guard.
    fn replyWriter(client: *Client) WriteError!*Io.Writer {
        if (builtin.is_test) {
            if (client.reply_override) |w| return w;
        }
        if (client.stdin_closed) return error.StdinClosed;
        if (client.transport_state.stopped.load(.acquire) or client.transport_state.failed.load(.acquire)) return error.TransportFailed;
        client.stdin_writer.begin();
        return &client.stdin_writer.interface;
    }

    // Render before writing to enforce the complete frame budget.
    fn writeLine(client: *Client, comptime f: anytype, args: anytype) WriteError!void {
        var buffer: [max_reply_line_bytes]u8 = undefined;
        const line = renderLine(&buffer, f, args) catch {
            client.transport_state.failed.store(true, .release);
            return error.ReplyTooLong;
        };
        try client.writeRendered(line);
    }

    // Outbound requests use the write deadline but not the control-reply cap.
    fn writeLineLocked(client: *Client, comptime f: anytype, args: anytype) WriteError!void {
        const w = try client.replyWriter();
        var js: std.json.Stringify = .{ .writer = w };
        @call(.auto, f, .{&js} ++ args) catch return client.writeFailure();
        finishLine(w) catch return client.writeFailure();
    }

    fn writeFailure(client: *Client) WriteError {
        if (builtin.is_test) {
            if (client.reply_override != null) return error.WriteFailed;
        }
        client.transport_state.failed.store(true, .release);
        client.state_mutex.lockUncancelable(client.io);
        if (client.initialization == .pending) client.initialization = .failed;
        client.state_mutex.unlock(client.io);
        return if (client.stdin_writer.timed_out) error.WriteTimedOut else error.WriteFailed;
    }

    fn renderLine(buffer: []u8, comptime f: anytype, args: anytype) error{ReplyTooLong}![]const u8 {
        var out: Io.Writer = .fixed(buffer);
        var js: std.json.Stringify = .{ .writer = &out };
        @call(.auto, f, .{&js} ++ args) catch return error.ReplyTooLong;
        out.writeByte('\n') catch return error.ReplyTooLong;
        return out.buffered();
    }

    fn writeRendered(client: *Client, line: []const u8) WriteError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        const w = try client.replyWriter();
        w.writeAll(line) catch return client.writeFailure();
        w.flush() catch return client.writeFailure();
    }

    fn sendInitialize(client: *Client) OpenError!void {
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        var id_buf: [32]u8 = undefined;
        const request_id = client.nextRequestId(&id_buf) catch unreachable;
        client.initialize_request = client.next_request_id;
        client.initialization = .pending;
        errdefer {
            client.pending_len -= 1;
            client.initialization = .failed;
        }
        client.writeLineLocked(protocol.writeInitialize, .{ request_id, client.servers, client.skills }) catch |err| switch (err) {
            error.StdinClosed, error.TooManyPendingRequests, error.ReplyTooLong => unreachable,
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

    // Fallbacks must obey the same complete-frame bound as successful replies.
    fn sendMcpResultBody(
        client: *Client,
        request_id: []const u8,
        message_id: ?std.json.Value,
        method: []const u8,
        comptime f: anytype,
        args: anytype,
    ) (WriteError || Allocator.Error)!void {
        var body_buffer: [max_reply_line_bytes]u8 = undefined;
        var body: Io.Writer = .fixed(&body_buffer);
        var js: std.json.Stringify = .{ .writer = &body };
        const body_ok = if (@call(.auto, f, .{&js} ++ args)) |_| true else |_| false;
        if (body_ok) {
            var frame_buffer: [max_reply_line_bytes]u8 = undefined;
            if (renderLine(&frame_buffer, protocol.writeMcpResult, .{ request_id, message_id, body.buffered() })) |line| {
                return client.writeRendered(line);
            } else |_| {}
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            var small_buffer: [512]u8 = undefined;
            var small: Io.Writer = .fixed(&small_buffer);
            var small_js: std.json.Stringify = .{ .writer = &small };
            protocol.results.toolCall(&small_js, ToolResult{
                .text = tool_result_too_long_message,
                .is_error = true,
            }) catch unreachable;
            return client.sendMcpResult(request_id, message_id, small.buffered());
        }
        return client.sendMcpError(request_id, message_id, -32603, "result too large: register fewer tools or shorten their metadata");
    }

    fn sendPermissionDecision(
        client: *Client,
        request_id: []const u8,
        input: std.json.Value,
        decision: PermissionDecision,
    ) (WriteError || Allocator.Error)!void {
        const reply: protocol.PermissionInput = switch (decision) {
            .deny => |message| {
                var buffer: [max_reply_line_bytes]u8 = undefined;
                if (renderLine(&buffer, protocol.writePermissionDeny, .{ request_id, message })) |line| {
                    return client.writeRendered(line);
                } else |_| {}
                return client.sendPermissionDeny(request_id, "permission reply too large; the call was denied");
            },
            .allow => .{ .value = input },
            .allow_with_input => |raw| blk: {
                if (!try isJsonObject(client.scratch.allocator(), raw)) {
                    return client.sendPermissionDeny(request_id, "permission handler returned an updated input that is not a JSON object; the call was denied");
                }
                break :blk .{ .raw = raw };
            },
        };
        var buffer: [max_reply_line_bytes]u8 = undefined;
        if (renderLine(&buffer, protocol.writePermissionAllow, .{ request_id, reply })) |line| {
            return client.writeRendered(line);
        } else |_| {}
        return client.sendPermissionDeny(request_id, "permission reply too large; the call was denied");
    }

    // --- control dispatch ---

    fn serveControlRequest(client: *Client, root: std.json.Value) (WriteError || Allocator.Error)!void {
        // Accept top-level and legacy nested IDs, including integers.
        const request = objectField(root, "request");
        var id_buf: [request_id_buf_len]u8 = undefined;
        const request_id = requestId(root, &id_buf) orelse
            (if (request) |r| requestId(r, &id_buf) else null) orelse
            // No usable id: a reply cannot be correlated.
            return;

        // Correlatable requests need a reply, including malformed requests.
        const req = request orelse
            return client.sendControlError(request_id, "missing request body");
        const subtype = stringField(req, "subtype") orelse
            return client.sendControlError(request_id, "missing request subtype");

        if (std.mem.eql(u8, subtype, "can_use_tool")) {
            return client.servePermissionRequest(request_id, req);
        }

        if (!std.mem.eql(u8, subtype, "mcp_message")) {
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
            // The CLI requires an empty MCP result with ID 0 for notifications.
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

            const call = tool.handler(tool.context, client.scratch.allocator(), arguments) catch |err| switch (err) {
                // Unblock the CLI before propagating host OOM.
                error.OutOfMemory => {
                    client.sendMcpError(request_id, message_id, -32603, "out of memory") catch {};
                    return error.OutOfMemory;
                },
                else => ToolResult{ .text = @errorName(err), .is_error = true },
            };

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

    fn servePermissionRequest(
        client: *Client,
        request_id: []const u8,
        req: std.json.Value,
    ) (WriteError || Allocator.Error)!void {
        const handler = client.permission_handler orelse
            return client.sendControlError(request_id, "unsupported control request");
        const tool_name = stringField(req, "tool_name") orelse
            return client.sendControlError(request_id, "missing tool_name");
        const input = objectField(req, "input") orelse std.json.Value{ .null = {} };

        client.resetScratch();

        // Handler errors become denials; answer OOM before propagating it.
        const decision = handler(client.permission_context, client.scratch.allocator(), tool_name, input) catch |err| switch (err) {
            error.OutOfMemory => {
                client.sendPermissionDeny(request_id, "out of memory") catch {};
                return error.OutOfMemory;
            },
            else => PermissionDecision{ .deny = @errorName(err) },
        };
        return client.sendPermissionDecision(request_id, input, decision);
    }

    // Reset between dispatches, after handler data has been written.
    fn resetScratch(client: *Client) void {
        _ = client.scratch.reset(.{ .retain_with_limit = retain_bytes });
    }

    // Ignore unknown IDs; only correlated rejections surface to the caller.
    fn noteControlResponse(client: *Client, root: std.json.Value) ReadError!void {
        const response = objectField(root, "response") orelse return;
        const request_id = stringField(response, "request_id") orelse return;
        const number = ownRequestNumber(request_id) orelse return;
        const subtype = stringField(response, "subtype") orelse return;
        if (!std.mem.eql(u8, subtype, "success") and !std.mem.eql(u8, subtype, "error")) return;
        // `interrupt` can append pending requests from another thread.
        client.write_mutex.lockUncancelable(client.io);
        defer client.write_mutex.unlock(client.io);
        const index = std.mem.indexOfScalar(u64, client.pending_requests[0..client.pending_len], number) orelse return;
        std.mem.copyForwards(
            u64,
            client.pending_requests[index .. client.pending_len - 1],
            client.pending_requests[index + 1 .. client.pending_len],
        );
        client.pending_len -= 1;

        const rejected = std.mem.eql(u8, subtype, "error");
        const initialize = client.initialize_request == number;
        if (initialize) {
            client.state_mutex.lockUncancelable(client.io);
            client.initialization = if (rejected) .rejected else .accepted;
            client.state_mutex.unlock(client.io);
        }
        if (!rejected) return;

        // Retain rejection text beyond the event's lifetime.
        const text = stringField(response, "error") orelse "(no error text)";
        const copy = try client.gpa.dupe(u8, text);
        if (client.control_error) |old| client.gpa.free(old);
        client.control_error = copy;
        return if (initialize) error.InitializationRejected else error.ControlRequestRejected;
    }

    // --- reading ---

    fn stdoutClosed(client: *Client) bool {
        client.state_mutex.lockUncancelable(client.io);
        defer client.state_mutex.unlock(client.io);
        return client.stdout_closed;
    }

    fn nextLine(client: *Client) ReadError!?[]const u8 {
        // Preserve `lastLine` until the next read before releasing large buffers.
        if (client.line.writer.buffer.len > retain_bytes) {
            client.line.deinit();
            client.line = .init(client.gpa);
        }
        return readLine(&client.stdout_reader.interface, &client.line, client.max_line_bytes) catch |err| {
            if (err == error.ReadFailed and client.transport_state.failed.load(.acquire)) return error.TransportFailed;
            return err;
        };
    }
};

fn forceCleanup(child: *std.process.Child, io: Io) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    if (child.id) |pid| {
        std.posix.kill(pid, .KILL) catch {};
        _ = child.wait(io) catch {};
    }
}

// Decimal i64 width, including sign.
const request_id_buf_len = 20;

// Borrow string IDs; render integer IDs into `buf`.
fn requestId(value: std.json.Value, buf: []u8) ?[]const u8 {
    return switch (objectField(value, "request_id") orelse return null) {
        .string => |s| s,
        .integer => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable,
        else => null,
    };
}

// Accept only canonical `zig_N` spellings emitted by this client.
fn ownRequestNumber(request_id: []const u8) ?u64 {
    const prefix = "zig_";
    if (!std.mem.startsWith(u8, request_id, prefix)) return null;
    const number = request_id[prefix.len..];
    if (number.len == 0 or number[0] == '0') return null;
    for (number) |digit| if (!std.ascii.isDigit(digit)) return null;
    return std.fmt.parseInt(u64, number, 10) catch null;
}

// Keep CLI values below Stringify's fixed nesting capacity.
fn jsonDepthWithin(text: []const u8) bool {
    var depth: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len) : (cursor += 1) {
        switch (text[cursor]) {
            '"' => {
                var search = cursor + 1;
                while (std.mem.indexOfScalarPos(u8, text, search, '"')) |quote| {
                    var escape_start = quote;
                    while (escape_start > cursor and text[escape_start - 1] == '\\') escape_start -= 1;
                    if ((quote - escape_start) % 2 == 0) {
                        cursor = quote;
                        break;
                    }
                    search = quote + 1;
                } else return true; // The JSON parser reports unterminated strings.
            },
            '{', '[' => {
                depth += 1;
                if (depth > 128) return false;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

fn isJsonObject(allocator: Allocator, text: []const u8) Allocator.Error!bool {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{' or !jsonDepthWithin(trimmed)) return false;
    return std.json.validate(allocator, trimmed);
}

// Escape command fragments directly into the user-message string.
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

fn readLine(
    r: *Io.Reader,
    line: *Io.Writer.Allocating,
    max_line_bytes: usize,
) ReadError!?[]const u8 {
    line.clearRetainingCapacity();
    // Include the delimiter; saturate so maxInt remains unlimited.
    _ = r.streamDelimiterLimit(
        &line.writer,
        '\n',
        .limited(max_line_bytes +| 1),
    ) catch |err| switch (err) {
        // Discard only this line's tail to preserve stream alignment.
        error.StreamTooLong => {
            _ = r.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                error.EndOfStream => {},
                error.ReadFailed => return error.ReadFailed,
            };
            return error.ProtocolTooLong;
        },
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
    };

    // `streamDelimiterLimit` leaves the delimiter buffered.
    if (r.bufferedLen() == 0) {
        const written = line.written();
        return if (written.len == 0) null else written;
    }
    r.toss(1);
    return line.written();
}

// --- tests ---

// Private read, write, dispatch, and adapter tests; public tests live in tests/.

const Expected = union(enum) {
    line: []const u8,
    end,
    fails: ReadError,
};

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
    try expectLines(
        "xxxxxxxxxxxxxxxxxxxx",
        8,
        &.{ .{ .fails = error.ProtocolTooLong }, .end },
    );
}

test "a line of exactly max_line_bytes is accepted" {
    try expectLines(
        "12345678\n{\"b\":2}\n",
        8,
        &.{ .{ .line = "12345678" }, .{ .line = "{\"b\":2}" }, .end },
    );
}

test "a line one byte over max_line_bytes is still rejected" {
    try expectLines(
        "123456789\n{\"b\":2}\n",
        8,
        &.{ .{ .fails = error.ProtocolTooLong }, .{ .line = "{\"b\":2}" }, .end },
    );
}

test "an exactly-max line without a trailing newline is accepted" {
    try expectLines("12345678", 8, &.{ .{ .line = "12345678" }, .end });
}

test "a max_line_bytes of maxInt does not wrap to a zero budget" {
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
    var r: Io.Reader = .fixed("xxxxxxxxxxxxxxxxxxxx\nnot json\n");
    var line: Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();

    try std.testing.expectError(error.ProtocolTooLong, readLine(&r, &line, 8));
    try std.testing.expectEqualStrings("xxxxxxxxx", line.written());

    try std.testing.expectEqualStrings("not json", (try readLine(&r, &line, 8)).?);
    try std.testing.expectEqualStrings("not json", line.written());
}

test "sendCommand builds the command turn without a temporary buffer" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCommandMessage(&out.writer, "code-review", "src/ \"quoted\"");

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

// Dispatch fixture using `out` instead of a child.
fn dispatchFixture(out: *Io.Writer.Allocating, servers: []const McpServer) Client {
    var client: Client = undefined;
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
    client.initialize_request = null;
    client.initialization = .not_required;
    client.transport_state = .{};
    client.stdin_closed = false;
    client.reply_override = &out.writer;
    return client;
}

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

fn parseReply(out: *Io.Writer.Allocating) !std.json.Parsed(std.json.Value) {
    const written = out.written();
    try std.testing.expect(written.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), written[written.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, written[0 .. written.len - 1], '\n') == null);
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, written, .{});
}

test "every malformed control request that can be answered is answered" {
    const cases = [_][]const u8{
        \\{"type":"control_request","request_id":"r1"}
        ,
        \\{"type":"control_request","request_id":"r2","request":{}}
        ,
        \\{"type":"control_request","request_id":"r3","request":{"subtype":"can_use_tool"}}
        ,
        \\{"type":"control_request","request":{"request_id":"r4"}}
        ,
        \\{"type":"control_request","request_id":"r5","request":{"subtype":"hook_callback"}}
        ,
    };

    for (cases, [_][]const u8{ "r1", "r2", "r3", "r4", "r5" }) |line, id| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try dispatch(&out, &.{}, line);

        try std.testing.expect(out.written().len > 0);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"control_response\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"subtype\":\"error\"") != null);
        const quoted = try std.fmt.allocPrint(std.testing.allocator, "\"request_id\":\"{s}\"", .{id});
        defer std.testing.allocator.free(quoted);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), quoted) != null);
        try std.testing.expectEqual(@as(u8, '\n'), out.written()[out.written().len - 1]);
    }
}

test "a control request with no id is the only silent path" {
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
    const cases = [_][]const u8{
        \\{"type":"control_request","request_id":7,"request":{"subtype":"hook_callback"}}
        ,
        \\{"type":"control_request","request":{"request_id":7,"subtype":"hook_callback"}}
    };
    for (cases) |line| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try dispatch(&out, &.{}, line);

        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"request_id\":\"7\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"subtype\":\"error\"") != null);
    }
}

test "a negative numeric request_id round-trips through the buffer" {
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

// Handshake fixtures list tools without calling them.
fn unreachableHandler(_: ?*anyopaque, _: Allocator, _: std.json.Value) anyerror!ToolResult {
    return error.NotCalled;
}

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

fn mcpResult(root: std.json.Value) ?std.json.Value {
    const response = objectField(root, "response") orelse return null;
    const inner = objectField(response, "response") orelse return null;
    const mcp = objectField(inner, "mcp_response") orelse return null;
    return objectField(mcp, "result");
}

test "initialize echoes the offered protocol version through the dispatch" {
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
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"request_id\":\"h1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":0") != null);
}

test "initialize falls back to the default protocol version" {
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
    const schema = objectField(tools[1], "inputSchema").?;
    try std.testing.expectEqualStrings("object", stringField(schema, "type").?);
    try std.testing.expect(objectField(objectField(schema, "properties").?, "name") != null);
}

fn oversizedHandler(context: ?*anyopaque, arena: Allocator, arguments: std.json.Value) anyerror!ToolResult {
    _ = arguments;
    const size: *const usize = @ptrCast(@alignCast(context.?));
    const text = try arena.alloc(u8, size.*);
    @memset(text, 'x');
    return .{ .text = text };
}

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
    var size: usize = max_tool_result_bytes + 1;
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchToolCall(&out, &size);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "xxxxxxxxxx") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tool result too long") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":true") != null);

    try std.testing.expect(out.written().len < 4096);
}

test "a tool result of exactly the cap is still delivered" {
    var size: usize = max_tool_result_bytes;
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchToolCall(&out, &size);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tool result too long") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"isError\":false") != null);
    // Measure the longest filler run; envelope fields may also contain `x`.
    var longest: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, out.written(), i, 'x')) |start| {
        const end = std.mem.indexOfNonePos(u8, out.written(), start, "x") orelse out.written().len;
        longest = @max(longest, end - start);
        i = end;
    }
    try std.testing.expectEqual(max_tool_result_bytes, longest);
    try std.testing.expect(out.written().len <= max_reply_line_bytes);
}

test "the bound is measured on the whole line, envelope included" {
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

// Escaping doubles an otherwise boundary-sized result.
fn quoteHandler(_: ?*anyopaque, arena: Allocator, _: std.json.Value) anyerror!ToolResult {
    const text = try arena.alloc(u8, max_tool_result_bytes);
    @memset(text, '"');
    return .{ .text = text };
}

// Valid schemas deliberately overflow the tools/list reply.
const wide_schema = "{\"type\":\"object\",\"properties\":{\"p\":{\"type\":\"string\",\"description\":\"" ++
    @as([960]u8, @splat('x')) ++ "\"}}}";
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
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "result too large") != null);
    try std.testing.expect(out.written().len <= max_reply_line_bytes);
}

test "an oversized initialize gets a jsonrpc error too" {
    const server: McpServer = .{ .name = &@as([max_reply_line_bytes + 1]u8, @splat('n')) };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{server},
        \\{"type":"control_request","request_id":"big","request":{"subtype":"mcp_message","server_name":"
    ++ @as([max_reply_line_bytes + 1]u8, @splat('n')) ++
        \\","message":{"id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}}}
    );
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "result too large") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"protocolVersion\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"content\"") == null);
}

fn oomHandler(_: ?*anyopaque, _: Allocator, _: std.json.Value) anyerror!ToolResult {
    return error.OutOfMemory;
}

test "a handler that runs out of memory still answers the CLI" {
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

    try std.testing.expectError(error.OutOfMemory, client.serveControlRequest(parsed.value));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "-32603") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "out of memory") != null);
    try std.testing.expectEqual(@as(u8, '\n'), out.written()[out.written().len - 1]);
}

// --- permission prompts ---

// Copy handler input because the dispatch arena is freed before assertions.
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
    _ = try arena.alloc(u8, 1);
    if (probe.fail) return error.HostRefused;
    return probe.decision;
}

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

fn permissionReply(root: std.json.Value) ?std.json.Value {
    const response = objectField(root, "response") orelse return null;
    return objectField(response, "response");
}

test "a permission allow echoes the proposed input back" {
    var probe: PermissionProbe = .{ .decision = .allow };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatchPermission(&out, &probe, bash_prompt);

    try std.testing.expectEqualStrings("Bash", probe.tool());
    try std.testing.expectEqualStrings("ls -la", probe.command());

    const parsed = try parseReply(&out);
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"subtype\":\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"request_id\":\"p1\"") != null);
    const reply = permissionReply(parsed.value).?;
    try std.testing.expectEqualStrings("allow", stringField(reply, "behavior").?);
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
    try std.testing.expect(objectField(updated, "timeout") == null);
}

test "a permission allow_with_input that is not an object becomes a deny" {
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
    const big = "{\"command\":\"" ++ @as([max_reply_line_bytes + 1]u8, @splat('y')) ++ "\"}";
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

fn responseFixture() Client {
    var client: Client = undefined;
    client.io = std.testing.io;
    client.write_mutex = .init;
    client.read_mutex = .init;
    client.state_mutex = .init;
    client.gpa = std.testing.allocator;
    client.next_request_id = 0;
    client.pending_len = 0;
    client.control_error = null;
    client.initialize_request = null;
    client.initialization = .not_required;
    client.transport_state = .{};
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
    try std.testing.expectEqualStrings("zig_1", try client.nextRequestId(&buf));
    try std.testing.expectEqual(@as(usize, 1), client.pending_len);

    try std.testing.expectError(error.ControlRequestRejected, noteResponse(&client,
        \\{"type":"control_response","response":{"subtype":"error","request_id":"zig_1","error":"sdkMcpServers rejected"}}
    ));
    try std.testing.expectEqualStrings("sdkMcpServers rejected", client.lastControlError().?);
    try std.testing.expectEqual(@as(usize, 0), client.pending_len);

    _ = try client.nextRequestId(&buf);
    try std.testing.expectError(error.ControlRequestRejected, noteResponse(&client,
        \\{"type":"control_response","response":{"subtype":"error","request_id":"zig_2"}}
    ));
    try std.testing.expectEqualStrings("(no error text)", client.lastControlError().?);
}

test "a success response is consumed silently" {
    var client = responseFixture();
    var buf: [32]u8 = undefined;
    _ = try client.nextRequestId(&buf);
    try noteResponse(&client,
        \\{"type":"control_response","response":{"subtype":"success","request_id":"zig_1","response":{}}}
    );
    try std.testing.expect(client.lastControlError() == null);
    try std.testing.expectEqual(@as(usize, 0), client.pending_len);
}

test "responses to ids this client never sent are left alone" {
    var client = responseFixture();
    var buf: [32]u8 = undefined;
    _ = try client.nextRequestId(&buf);
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
    try std.testing.expectEqual(@as(usize, 1), client.pending_len);
}

test "own request IDs require the exact emitted decimal spelling" {
    const valid = .{
        .{ "zig_1", @as(u64, 1) },
        .{ "zig_10", @as(u64, 10) },
        .{ "zig_18446744073709551615", std.math.maxInt(u64) },
    };
    inline for (valid) |case| try std.testing.expectEqual(@as(?u64, case[1]), ownRequestNumber(case[0]));
    for ([_][]const u8{
        "",        "zig_",   "zig_0",                    "zig_00",  "zig_01",    "zig_+1", "zig_-1",
        "zig_1_0", "zig_ 1", "zig_1 ",                   "zig_1\n", "zig_1\x00",
        "zig_١",
        "zig_0x1", "ZIG_1",  "zig_18446744073709551616",
    }) |id| try std.testing.expectEqual(@as(?u64, null), ownRequestNumber(id));
}

test "maximum request ID round-trips without wrapping or losing correlation" {
    var client = responseFixture();
    client.next_request_id = std.math.maxInt(u64) - 1;
    var id: [32]u8 = undefined;
    const emitted = try client.nextRequestId(&id);
    try std.testing.expectEqualStrings("zig_18446744073709551615", emitted);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), ownRequestNumber(emitted));
    try noteResponse(&client,
        \\{"response":{"subtype":"success","request_id":"zig_18446744073709551615"}}
    );
    try std.testing.expectEqual(@as(usize, 0), client.pending_len);
    try std.testing.expectError(error.TooManyPendingRequests, client.nextRequestId(&id));
    try std.testing.expectEqual(std.math.maxInt(u64), client.next_request_id);
}

test "noncanonical response IDs preserve initialization until an exact acknowledgement" {
    for ([_]bool{ false, true }) |reject_initialize| {
        var client = responseFixture();
        defer if (client.control_error) |text| std.testing.allocator.free(text);
        var id: [32]u8 = undefined;
        _ = try client.nextRequestId(&id);
        client.initialize_request = 1;
        client.initialization = .pending;
        _ = try client.nextRequestId(&id);
        for ([_][]const u8{ "zig_01", "zig_+1", "zig_0001", "zig_ 1", "zig_1 ", "zig_02", "zig_+2" }) |wrong_id| {
            for ([_][]const u8{ "success", "error" }) |subtype| {
                const line = try std.fmt.allocPrint(std.testing.allocator, "{{\"response\":{{\"subtype\":\"{s}\",\"request_id\":\"{s}\",\"error\":\"unmatched\"}}}}", .{ subtype, wrong_id });
                defer std.testing.allocator.free(line);
                try noteResponse(&client, line);
                try std.testing.expectEqual(@as(usize, 2), client.pending_len);
                try std.testing.expectEqual(@as(u64, 1), client.pending_requests[0]);
                try std.testing.expectEqual(@as(u64, 2), client.pending_requests[1]);
                try std.testing.expectEqual(InitializationState.pending, client.initialization);
                try std.testing.expect(client.lastControlError() == null);
            }
        }
        if (reject_initialize) {
            try std.testing.expectError(error.InitializationRejected, noteResponse(&client,
                \\{"response":{"subtype":"error","request_id":"zig_1","error":"initialize refused"}}
            ));
            try std.testing.expectEqual(InitializationState.rejected, client.initialization);
            try std.testing.expectEqualStrings("initialize refused", client.lastControlError().?);
        } else {
            try noteResponse(&client,
                \\{"response":{"subtype":"success","request_id":"zig_1"}}
            );
            try std.testing.expectEqual(InitializationState.accepted, client.initialization);
        }
        try std.testing.expectEqual(@as(usize, 1), client.pending_len);
        try std.testing.expectEqual(@as(u64, 2), client.pending_requests[0]);
        try std.testing.expectError(error.ControlRequestRejected, noteResponse(&client,
            \\{"response":{"subtype":"error","request_id":"zig_2","error":"interrupt refused"}}
        ));
        try std.testing.expectEqualStrings("interrupt refused", client.lastControlError().?);
        try std.testing.expectEqual(@as(usize, 0), client.pending_len);
    }
}

test "the pending list rejects overflow without discarding accepted requests" {
    var client = responseFixture();
    var buf: [32]u8 = undefined;
    for (0..max_pending_requests) |_| _ = try client.nextRequestId(&buf);
    try std.testing.expectError(error.TooManyPendingRequests, client.nextRequestId(&buf));
    try std.testing.expectEqual(@as(usize, max_pending_requests), client.pending_len);
    try std.testing.expectEqual(@as(u64, 1), client.pending_requests[0]);
    try std.testing.expectEqual(@as(u64, max_pending_requests), client.pending_requests[client.pending_len - 1]);
}

// --- live child ---

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
    var stub = try StubChild.init("#!/bin/sh\nexit 0\n");
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try std.testing.expect(client.child.stdout == null);
    try std.testing.expect(client.child.stdin != null);
}

test "open rejects a zero max_line_bytes instead of failing forever" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.InvalidMaxLineBytes, Client.open(
        std.testing.allocator,
        threaded.io(),
        .{ .max_line_bytes = 0 },
    ));
    const e: OpenError = error.InvalidMaxLineBytes;
    try std.testing.expectEqual(OpenError.InvalidMaxLineBytes, e);
}

test "open rejects a tool schema that is not a JSON object before spawning" {
    // An invalid binary path proves schema validation precedes spawning.
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

    const tools = [_]tool_mod.Tool{.{ .name = "t", .description = "d", .input_schema = "  {}", .handler = unreachableHandler }};
    const servers = [_]McpServer{.{ .name = "s", .tools = &tools }};
    try std.testing.expectError(error.FileNotFound, Client.open(
        std.testing.allocator,
        threaded.io(),
        .{ .claude_path = "/nonexistent/claude", .sdk_mcp_servers = &servers },
    ));
}

test "killed pairs with term rather than replacing it" {
    var client: Client = undefined;
    client.io = std.testing.io;
    client.write_mutex = .init;
    client.read_mutex = .init;
    client.state_mutex = .init;
    client.term = null;
    client.wait_error = null;
    client.killed = false;
    try std.testing.expect(!client.killed);

    client.term = .{ .signal = std.posix.SIG.TERM };
    client.killed = true;
    try std.testing.expect(client.killed);
    try std.testing.expectEqual(std.posix.SIG.TERM, client.term.?.signal);
}

test "kill still runs after a failed reap" {
    var stub = try StubChild.init("#!/bin/sh\ntrap '' PIPE\nsleep 3\nexit 0\n");
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    client.wait_error = error.Unexpected;
    client.kill();

    try std.testing.expect(client.killed);
    try std.testing.expectEqual(std.posix.SIG.TERM, client.term.?.signal);
}

test "a rejected initialize surfaces from next with the CLI's text" {
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
    try std.testing.expectError(error.InitializationRejected, client.next());
    try std.testing.expectEqualStrings("sdkMcpServers rejected", client.lastControlError().?);

    try std.testing.expectError(error.InvalidJson, client.next());
    try std.testing.expectEqualStrings("not json", client.lastLine());

    var event = (try client.next()).?;
    defer event.deinit();
    try std.testing.expectEqual(Kind.result, event.kind);
    try std.testing.expect(std.mem.startsWith(u8, client.lastLine(), "{\"type\":\"result\""));
    try std.testing.expect(try client.next() == null);
    try std.testing.expectEqual(@as(usize, 0), client.lastLine().len);
}

test "a control request arriving after closeStdin is refused, not written blind" {
    var client: Client = undefined;
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

    try std.testing.expectError(error.StdinClosed, client.serveControlRequest(parsed.value));

    const e: ReadError = error.StdinClosed;
    try std.testing.expectEqual(ReadError.StdinClosed, e);
}

// --- fuzz ---

// Fuzz private line reading and dispatch; normal tests run the seed corpus.

fn fuzzReadLine(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const input = buf[0..smith.sliceWithHash(&buf, 0x7ead11)];
    // A fixed-width integer, since the fuzz ABI cannot describe `usize`.
    const max_line_bytes: usize = smith.valueRangeAtMostWithHash(u8, 1, 128, 0x7ead12);

    var r: Io.Reader = .fixed(input);
    var line: Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();

    // Bound read attempts to detect resynchronization loops.
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
    if (!jsonDepthWithin(input)) return;

    // Only valid JSON reaches dispatch in `next`.
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

    var id_buf: [request_id_buf_len]u8 = undefined;
    const request = objectField(parsed.value, "request");
    const id = requestId(parsed.value, &id_buf) orelse
        (if (request) |value| requestId(value, &id_buf) else null);
    const written = out.written();
    if (id) |expected_id| {
        try std.testing.expect(written.len > 0 and written.len <= max_reply_line_bytes);
        try std.testing.expectEqual(@as(?usize, written.len - 1), std.mem.indexOfScalar(u8, written, '\n'));
        const reply = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, written, .{});
        defer reply.deinit();
        const envelope = objectField(reply.value, "response").?;
        try std.testing.expectEqualStrings(expected_id, stringField(envelope, "request_id").?);
    } else {
        try std.testing.expectEqual(@as(usize, 0), written.len);
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

test "complete reply boundaries include escaped metadata and the newline" {
    var storage: [max_reply_line_bytes]u8 = undefined;
    const empty = try Client.renderLine(&storage, protocol.writeControlError, .{ "r", "" });
    const overhead = empty.len;
    var text: [max_reply_line_bytes]u8 = @splat('x');
    for ([_]usize{ max_reply_line_bytes - 1, max_reply_line_bytes }) |length| {
        const frame = try Client.renderLine(&storage, protocol.writeControlError, .{ "r", text[0 .. length - overhead] });
        try std.testing.expectEqual(length, frame.len);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, frame, .{});
        parsed.deinit();
    }
    try std.testing.expectError(error.ReplyTooLong, Client.renderLine(&storage, protocol.writeControlError, .{ "r", text[0 .. max_reply_line_bytes + 1 - overhead] }));
    @memset(&text, '"');
    const escaped_length = (max_reply_line_bytes - overhead) / 2;
    _ = try Client.renderLine(&storage, protocol.writeControlError, .{ "r", text[0..escaped_length] });
    try std.testing.expectError(error.ReplyTooLong, Client.renderLine(&storage, protocol.writeControlError, .{ "r", text[0 .. escaped_length + 1] }));
}

test "large permission denials use a bounded correlated fallback" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var client = dispatchFixture(&out, &.{});
    defer client.scratch.deinit();
    const denial: [64 * 1024]u8 = @splat('"');
    try client.sendPermissionDecision("request\"id", .null, .{ .deny = &denial });
    const parsed = try parseReply(&out);
    defer parsed.deinit();
    try std.testing.expect(out.written().len <= max_reply_line_bytes);
    const response = objectField(parsed.value, "response").?;
    try std.testing.expectEqualStrings("request\"id", stringField(response, "request_id").?);
    try std.testing.expectEqualStrings("deny", stringField(permissionReply(parsed.value).?, "behavior").?);
}

test "oversized correlation metadata is terminal on every reply path" {
    const large: [64 * 1024]u8 = @splat('i');
    const server: McpServer = .{ .name = "s" };
    for (0..5) |case| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var client = dispatchFixture(&out, &.{server});
        defer client.scratch.deinit();
        const result = switch (case) {
            0 => client.sendControlError(&large, "unsupported request"),
            1 => client.sendPermissionDecision(&large, .null, .{ .deny = &large }),
            2 => client.sendMcpError("r", .{ .string = &large }, -32601, "unknown server"),
            3 => client.sendMcpResultBody(&large, .{ .integer = 1 }, "tools/list", protocol.results.toolsList, .{&server}),
            else => client.sendMcpResultBody("r", .{ .string = &large }, "tools/call", protocol.results.toolCall, .{ToolResult{ .text = &large }}),
        };
        try std.testing.expectError(error.ReplyTooLong, result);
        try std.testing.expectEqual(@as(usize, 0), out.written().len);
        try std.testing.expect(client.transport_state.failed.load(.acquire));
    }
}

test "pretty printed schemas and replacement inputs remain a single JSON line" {
    const server: McpServer = .{ .name = "s", .tools = &.{.{
        .name = "t",
        .description = "d",
        .handler = unreachableHandler,
        .input_schema = "{\n \"type\": \"object\",\n \"description\": \"a \\\"quoted\\\" string\"\n}",
    }} };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try dispatch(&out, &.{server},
        \\{"request_id":"r","request":{"subtype":"mcp_message","server_name":"s","message":{"id":7,"method":"tools/list"}}}
    );
    const listed = try parseReply(&out);
    defer listed.deinit();
    out.clearRetainingCapacity();
    var client = dispatchFixture(&out, &.{});
    defer client.scratch.deinit();
    try client.sendPermissionDecision("p", .null, .{ .allow_with_input = "{\n \"command\": \"echo a b\"\n}" });
    const allowed = try parseReply(&out);
    defer allowed.deinit();
    const updated = objectField(permissionReply(allowed.value).?, "updatedInput").?;
    try std.testing.expectEqualStrings("echo a b", stringField(updated, "command").?);
}

test "pending saturation preserves initialization rejection and ignores duplicates" {
    var client = responseFixture();
    defer if (client.control_error) |value| std.testing.allocator.free(value);
    var id: [32]u8 = undefined;
    _ = try client.nextRequestId(&id);
    client.initialize_request = 1;
    client.initialization = .pending;
    for (1..max_pending_requests) |_| _ = try client.nextRequestId(&id);
    for (0..32) |_| try std.testing.expectError(error.TooManyPendingRequests, client.nextRequestId(&id));
    try noteResponse(&client,
        \\{"response":{"request_id":"zig_1","subtype":"unexpected"}}
    );
    try std.testing.expectEqual(@as(usize, max_pending_requests), client.pending_len);
    try std.testing.expectError(error.InitializationRejected, noteResponse(&client,
        \\{"response":{"request_id":"zig_1","subtype":"error","error":"unconfigured"}}
    ));
    try std.testing.expectEqual(InitializationState.rejected, client.initialization);
    try noteResponse(&client,
        \\{"response":{"request_id":"zig_1","subtype":"success"}}
    );
    try std.testing.expectEqual(InitializationState.rejected, client.initialization);
    try std.testing.expectEqual(@as(u64, 2), client.pending_requests[0]);
}

fn allocatingToolResult(_: ?*anyopaque, arena: Allocator, _: std.json.Value) anyerror!ToolResult {
    return .{ .text = try arena.dupe(u8, "done") };
}

fn allocatingPermission(_: ?*anyopaque, arena: Allocator, _: []const u8, _: std.json.Value) anyerror!PermissionDecision {
    return .{ .deny = try arena.dupe(u8, "not allowed") };
}

fn dispatchAllocationFailures(allocator: Allocator, permission: bool) !void {
    var allocated: Io.Writer.Allocating = .init(allocator);
    defer allocated.deinit();
    var fixed_buffer: [max_reply_line_bytes]u8 = undefined;
    var fixed: Io.Writer = .fixed(&fixed_buffer);
    var client = dispatchFixture(&allocated, &.{.{ .name = "s", .tools = &.{.{
        .name = "t",
        .description = "d",
        .handler = allocatingToolResult,
    }} }});
    client.gpa = allocator;
    client.scratch = .init(allocator);
    defer client.scratch.deinit();
    client.reply_override = &fixed;
    client.permission_handler = allocatingPermission;
    const input = if (permission)
        \\{"request_id":"p","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}
    else
        \\{"request_id":"t","request":{"subtype":"mcp_message","server_name":"s","message":{"id":3,"method":"tools/call","params":{"name":"t","arguments":{}}}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try client.serveControlRequest(parsed.value);
    const reply = try std.json.parseFromSlice(std.json.Value, allocator, fixed.buffered(), .{});
    defer reply.deinit();
    try std.testing.expect(fixed.end <= max_reply_line_bytes);
}

fn stableAllocation(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
    const backing: *Allocator = @ptrCast(@alignCast(raw));
    return backing.rawAlloc(len, alignment, ret);
}

fn stableFree(raw: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
    const backing: *Allocator = @ptrCast(@alignCast(raw));
    backing.rawFree(bytes, alignment, ret);
}

test "control and permission dispatch clean up every allocation failure" {
    // Arena growth must take the same allocation path in each failure sweep.
    var backing = std.testing.allocator;
    const stable: Allocator = .{ .ptr = &backing, .vtable = &.{
        .alloc = stableAllocation,
        .resize = Allocator.noResize,
        .remap = Allocator.noRemap,
        .free = stableFree,
    } };
    try std.testing.checkAllAllocationFailures(stable, dispatchAllocationFailures, .{false});
    try std.testing.checkAllAllocationFailures(stable, dispatchAllocationFailures, .{true});
}

const ReapSignalProbe = struct {
    kernel_reaped: std.atomic.Value(bool) = .init(false),
    release_reap: std.atomic.Value(bool) = .init(false),
    signal_attempted: std.atomic.Value(bool) = .init(false),
    signal_finished: std.atomic.Value(bool) = .init(false),
    signals: usize = 0,
    result: ?std.process.Child.Term = null,

    fn poll(raw: *anyopaque, child: *std.process.Child) std.process.Child.WaitError!?std.process.Child.Term {
        const probe: *ReapSignalProbe = @ptrCast(@alignCast(raw));
        probe.kernel_reaped.store(true, .release);
        while (!probe.release_reap.load(.acquire)) std.Thread.yield() catch {};
        child.id = null;
        return .{ .exited = 7 };
    }
    fn signal(raw: *anyopaque, _: std.process.Child.Id, _: std.posix.SIG) void {
        const probe: *ReapSignalProbe = @ptrCast(@alignCast(raw));
        probe.signals += 1;
    }
    fn waitThread(probe: *ReapSignalProbe, client: *Client) void {
        probe.result = client.awaitExit(null) catch null;
    }
    fn signalThread(probe: *ReapSignalProbe, client: *Client) void {
        probe.signal_attempted.store(true, .release);
        client.requestSignal(.TERM);
        probe.signal_finished.store(true, .release);
    }
};

test "signal cannot enter the kernel-reap to status-publication interval" {
    var client = responseFixture();
    client.child = .{ .id = 123, .thread_handle = {}, .stdin = null, .stdout = null, .stderr = null, .request_resource_usage_statistics = false };
    client.term = null;
    client.wait_error = null;
    client.killed = false;
    client.force_killed = false;
    client.stdout_closed = false;
    var probe: ReapSignalProbe = .{};
    client.process_override = .{ .context = &probe, .poll = ReapSignalProbe.poll, .signal = ReapSignalProbe.signal };
    const waiter = try std.Thread.spawn(.{}, ReapSignalProbe.waitThread, .{ &probe, &client });
    var waiter_joined = false;
    defer if (!waiter_joined) {
        probe.release_reap.store(true, .release);
        waiter.join();
    };
    while (!probe.kernel_reaped.load(.acquire)) std.Thread.yield() catch {};
    const reap_locked = !client.state_mutex.tryLock();
    if (!reap_locked) client.state_mutex.unlock(client.io);
    const signaler = try std.Thread.spawn(.{}, ReapSignalProbe.signalThread, .{ &probe, &client });
    var signaler_joined = false;
    defer if (!signaler_joined) {
        probe.release_reap.store(true, .release);
        signaler.join();
    };
    while (!probe.signal_attempted.load(.acquire)) std.Thread.yield() catch {};
    // Give an unlocked signaler time to cross the simulated kernel-reap gap.
    std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    const signal_blocked = !probe.signal_finished.load(.acquire);
    probe.release_reap.store(true, .release);
    waiter.join();
    waiter_joined = true;
    signaler.join();
    signaler_joined = true;
    try std.testing.expect(reap_locked);
    try std.testing.expect(signal_blocked);
    try std.testing.expectEqual(@as(usize, 0), probe.signals);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, probe.result.?);
    try std.testing.expectEqual(probe.result.?, client.term.?);
}

test "nesting policy accepts its boundary and ignores brackets inside strings" {
    const at_limit = @as([128]u8, @splat('[')) ++ "0" ++ @as([128]u8, @splat(']'));
    const over_limit = "[" ++ at_limit ++ "]";
    try std.testing.expect(jsonDepthWithin(at_limit));
    try std.testing.expect(!jsonDepthWithin(over_limit));
    try std.testing.expect(jsonDepthWithin("\"" ++ @as([300]u8, @splat('[')) ++ "\\\"quoted\\\"\""));
    try std.testing.expect(!try isJsonObject(std.testing.allocator, "{\"p\":" ++ at_limit ++ "}"));

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var client = dispatchFixture(&out, &.{});
    defer client.scratch.deinit();
    try client.sendPermissionDecision("r", .null, .{ .allow_with_input = "{\"p\":" ++ at_limit ++ "}" });
    const parsed = try parseReply(&out);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("deny", stringField(permissionReply(parsed.value).?, "behavior").?);
}

test "nesting scanner distinguishes escaped quotes by backslash parity" {
    const nested = @as([128]u8, @splat('[')) ++ "0" ++ @as([128]u8, @splat(']'));
    for (0..9) |slashes| {
        var raw: Io.Writer.Allocating = .init(std.testing.allocator);
        defer raw.deinit();
        try raw.writer.writeAll("{\"p\":\"");
        try raw.writer.splatByteAll('\\', slashes);
        try raw.writer.writeByte('"');
        if (slashes % 2 == 0) {
            try raw.writer.writeAll(",\"q\":" ++ nested ++ "}");
        } else {
            try raw.writer.splatByteAll('[', 300);
            try raw.writer.writeAll("\",\"q\":0}");
        }
        try std.testing.expect(try std.json.validate(std.testing.allocator, raw.written()));
        try std.testing.expectEqual(slashes % 2 != 0, jsonDepthWithin(raw.written()));
    }
}
