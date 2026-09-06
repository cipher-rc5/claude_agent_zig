// tests/integration_test.zig
// End-to-end tests that drive the real `Client` against scripted stub CLIs.
//
// Every other test in the suite stops at the module boundary, leaving `open`,
// `next`, `wait`, `kill`, and `close` — the process lifecycle over a real pipe
// — covered only by inspection. These tests close that gap.
//
// Each stub is a `#!/bin/sh` script written to a temp dir at runtime and
// pointed at by `Options.claude_path`. Writing it at runtime avoids assuming a
// cwd and keeps an executable out of the repository. Every stub terminates on
// its own, so nothing here can hang `just ci`.

const std = @import("std");
const agent = @import("agent");

const io = std.testing.io;
const gpa = std.testing.allocator;

/// A stub CLI on disk, plus the temp dir holding it. `deinit` removes both.
const Stub = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    /// Writes `script` as an executable `#!/bin/sh` file and resolves its
    /// absolute path. Absolute because `std.process.spawn` resolves a bare
    /// name through PATH and a relative one against the process cwd, neither
    /// of which this test controls.
    fn init(script: []const u8) !Stub {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        try tmp.dir.writeFile(io, .{
            .sub_path = "stub.sh",
            .data = script,
            // Without the executable bit the spawn fails with AccessDenied
            // rather than running anything.
            .flags = .{ .permissions = .executable_file },
        });

        return .{
            .tmp = tmp,
            .path = try tmp.dir.realPathFileAlloc(io, "stub.sh", gpa),
        };
    }

    fn deinit(stub: *Stub) void {
        gpa.free(stub.path);
        stub.tmp.cleanup();
        stub.* = undefined;
    }

    fn open(stub: *const Stub, options: agent.Options) !*agent.Client {
        var with_path = options;
        with_path.claude_path = stub.path;
        return agent.Client.open(gpa, io, with_path);
    }
};

/// Reads to end of stream, freeing each event, and reports how many
/// conversation events arrived. Control traffic is serviced inside `next` and
/// never counted here, which is what makes the count meaningful.
fn drain(client: *agent.Client) !usize {
    var count: usize = 0;
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        count += 1;
    }
    return count;
}

/// Two protocol lines and a clean exit: the shortest complete session.
///
/// `trap '' PIPE` is load-bearing rather than decorative. The client closes
/// stdin on the way into `wait`, and under enough CPU load that can land while
/// the shell is still between its two `printf`s. The shell would then die of
/// SIGPIPE and report `.signal`, failing a test that asserts `.exited = 0` for
/// reasons that have nothing to do with the client. Ignoring the signal keeps
/// the exit status the stub's own.
const two_line_stub =
    \\#!/bin/sh
    \\trap '' PIPE
    \\printf '{"type":"system","subtype":"init","session_id":"S1"}\n'
    \\printf '{"type":"result","result":"done"}\n'
    \\exit 0
    \\
;

// --- regression: the stdout use-after-free ---

test "next after wait reports end of stream instead of reading a stale fd" {
    // THE REGRESSION. `Io.File.Reader` holds the `File` by value, so reaping
    // the child closes the descriptor inside the stdlib while the reader keeps
    // a stale copy of the number. Reading through that copy once the number
    // has been recycled parses whatever unrelated file now owns it and hands
    // it back as a genuine event. `stdout_closed`, set by `wait`, is what
    // makes `next` answer end-of-stream instead of touching the reader.
    //
    // Without the guard this test does not merely return a wrong value — the
    // read goes out through a closed descriptor and the call fails. Either way
    // the `== null` below stops holding, which is the point.
    var stub = try Stub.init(two_line_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try std.testing.expectEqual(@as(usize, 2), try drain(client));
    _ = try client.wait();

    // The child is reaped. Every later read is answered from the flag.
    try std.testing.expect(try client.next() == null);
    try std.testing.expect(try client.next() == null);
}

test "next after kill also reports end of stream" {
    // `kill` reaps too, by a different path, and leaves the same stale
    // descriptor behind. It sets `stdout_closed` for the same reason.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\printf '{"type":"system","subtype":"init","session_id":"K1"}\n'
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    _ = try drain(client);
    client.kill();
    try std.testing.expect(try client.next() == null);
}

// --- regression: the tool-reply size cap ---

/// Handler returning `context` bytes of filler. The size travels through the
/// context pointer so one handler can drive both sides of the bound.
fn fillerHandler(context: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) anyerror!agent.ToolResult {
    _ = arguments;
    const size: *const usize = @ptrCast(@alignCast(context.?));
    const text = try arena.alloc(u8, size.*);
    @memset(text, 'x');
    return .{ .text = text };
}

/// Records that the handler ran, and what it was passed.
const CallRecord = struct {
    ran: bool = false,
    /// The `n` argument the stub sent, so the test can prove the arguments
    /// survived the round trip rather than the handler merely firing.
    n: i64 = 0,
};

fn recordingHandler(context: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) anyerror!agent.ToolResult {
    _ = arena;
    const record: *CallRecord = @ptrCast(@alignCast(context.?));
    record.ran = true;
    if (arguments == .object) {
        if (arguments.object.get("n")) |v| {
            if (v == .integer) record.n = v.integer;
        }
    }
    return .{ .text = "ok" };
}

/// The `tools/call` control request every tool test drives, as one line.
///
/// `server_name` and the tool name match the fixtures below; `arguments`
/// carries an `n` the handler can echo back to prove the payload survived.
const tool_call_line =
    \\printf '{"type":"control_request","request_id":"c1","request":{"subtype":"mcp_message","server_name":"s","message":{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"t","arguments":{"n":41}}}}}\n'
;

/// Reads the `initialize` line `open` sends before anything else, then the
/// tool reply, leaving the reply in `$reply`.
///
/// Both reads are mandatory and in this order: `open` writes `initialize`
/// before the test reads anything, so a stub that reads once consumes that
/// line and then EPIPEs the real reply.
///
/// `|| exit 0` bounds each read — a reply that never comes ends as EOF rather
/// than a block, so the test fails on a missing event instead of hanging.
const read_reply =
    \\IFS= read -r init_line || exit 0
    \\IFS= read -r reply || exit 0
;

/// Issues one `tools/call`, consumes the reply, and exits cleanly.
///
/// Reaching `exit 0` at all is the assertion: the stub only gets there after
/// both reads returned real lines, so a clean exit means the reply was
/// written, flushed, and newline-terminated on a real pipe.
const tool_call_stub =
    "#!/bin/sh\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"T1\"}\\n'\n" ++
    tool_call_line ++ "\n" ++
    read_reply ++ "\n" ++
    "printf '{\"type\":\"result\",\"result\":\"replied\"}\\n'\n" ++
    "exit 0\n";

test "a tools/call from the child runs the handler and the reply reaches the child" {
    // The library's core feature, end to end: the CLI asks this process to run
    // one of its in-process tools, `next` dispatches it without surfacing the
    // control line, and the answer goes back down the child's stdin. Every
    // other test of this path stops at `reply_override` and never touches a
    // pipe.
    var record: CallRecord = .{};
    const servers = [_]agent.McpServer{.{
        .name = "s",
        .tools = &.{.{
            .name = "t",
            .description = "d",
            .handler = recordingHandler,
            .context = &record,
        }},
    }};

    var stub = try Stub.init(tool_call_stub);
    defer stub.deinit();

    const client = try stub.open(.{ .sdk_mcp_servers = &servers });
    defer _ = client.close();

    // Two conversation events. The control_request in between is serviced
    // inside `next` and never handed out, so a count of 3 would mean the
    // dispatch had been skipped.
    try std.testing.expectEqual(@as(usize, 2), try drain(client));

    try std.testing.expect(record.ran);
    // The arguments survived the trip, so this is a real dispatch and not the
    // handler being invoked with an empty payload.
    try std.testing.expectEqual(@as(i64, 41), record.n);

    // The stub only reaches its `result` line after `read` returns, so the
    // reply was written, flushed, and newline-terminated on the real pipe.
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try client.wait());
}

/// A stub that issues one `tools/call` and then never reads its stdin at all.
///
/// The shape `max_tool_result_bytes` exists for: nobody drains the child's
/// stdin, so the whole reply has to fit in the pipe buffer unread or the write
/// blocks forever.
///
/// It queues its output first, then sleeps so it is still alive when the
/// reply is written; a stub that had already exited would EPIPE the write
/// before the bound was exercised. The test kills it as soon as the reply has
/// landed, so the sleep is a ceiling on the stub's lifetime that nothing
/// waits out, and long enough that no loaded host reaches it first — a short
/// one turned the test into a race against spawn plus a 4 MiB allocation.
/// `exec`, so the signal lands on the sleep itself rather than on a shell
/// that would leave it orphaned, holding the pipe for the rest of the sleep.
const no_read_stub =
    "#!/bin/sh\n" ++
    tool_call_line ++ "\n" ++
    "printf '{\"type\":\"result\",\"result\":\"done\"}\\n'\n" ++
    "exec sleep 5\n";

/// Runs `body` under a deadline, failing the test if it outlives one.
///
/// A regression in `max_tool_result_bytes` deadlocks rather than fails, so the
/// test asserting that bound has to bound its own runtime or it hangs `just ci`
/// instead of failing it.
///
/// `Io.Threaded` cancels by `pthread_kill`-ing the blocked thread with `SIGIO`,
/// which returns `EINTR` out of the syscall, so `cancelDiscard` genuinely
/// unblocks a `writev` stuck on a full pipe rather than just abandoning it.
///
/// `body` returns a bool because its result crosses a task boundary into the
/// select's union. Not a general-purpose harness: every other test here is
/// bounded by its stub exiting on its own.
fn underDeadline(comptime body: fn () bool, millis: i64) !void {
    const Race = union(enum) { body: bool, deadline: void };

    const tasks = struct {
        fn run() bool {
            return body();
        }
        fn timer(ms: i64) void {
            // A cancel arrives here as `error.Canceled` once `body` wins the
            // race, which is the normal path and not a failure.
            io.sleep(.fromMilliseconds(ms), .awake) catch {};
        }
    };

    var buf: [2]Race = undefined;
    var race: std.Io.Select(Race) = .init(io, &buf);
    try race.concurrent(.body, tasks.run, .{});
    try race.concurrent(.deadline, tasks.timer, .{millis});

    const first = try race.await();
    // Cancels whichever task lost. When that is `body`, this is the call that
    // interrupts its blocked syscall, so the test process still exits.
    race.cancelDiscard();

    switch (first) {
        .body => |ok| try std.testing.expect(ok),
        // The deadline won: `body` was still inside `next`, which is the
        // deadlock this bound exists to prevent.
        .deadline => return error.DeadlineExceeded,
    }
}

/// The body of the test below, lifted out so `underDeadline` can run it as a
/// task. Returns false instead of raising, per that function's contract.
fn oversizedToolResultFitsPipe() bool {
    var size: usize = 4 * 1024 * 1024;
    const servers = [_]agent.McpServer{.{
        .name = "s",
        .tools = &.{.{
            .name = "t",
            .description = "d",
            .handler = fillerHandler,
            .context = &size,
        }},
    }};

    var stub = Stub.init(no_read_stub) catch return false;
    defer stub.deinit();

    const client = stub.open(.{ .sdk_mcp_servers = &servers }) catch return false;
    defer _ = client.close();

    // The first `next` services the control request — writing the reply into
    // a pipe nobody drains — and only then returns the `result` line queued
    // behind it. Reaching the second statement at all is the assertion.
    var event = (client.next() catch return false) orelse return false;
    const ok = event.kind == .result;
    event.deinit();

    // Not drained to end of stream: that would wait for the stub's sleep to
    // expire. It is killed instead, which is what the sleep is for.
    client.kill();
    return ok;
}

test "an oversized tool result fits the pipe even when the child never reads" {
    // The stub never reads its stdin, so the bound is the only thing keeping
    // the write non-blocking. A 4 MiB result is replaced by a short `is_error`
    // payload that fits one pipe load, so `next` completes.
    //
    // 4 MiB rather than one byte over the cap: a payload just past the bound
    // still fits a 64 KiB pipe and would pass either way. The boundary itself
    // is covered by `tool result one byte over the cap` below.
    //
    // Under a deadline because a regression here hangs rather than fails.
    // Nothing on the passing path waits — the stub is killed the moment the
    // result line is read — so only a `next` stuck in `writev` reaches it.
    try underDeadline(oversizedToolResultFitsPipe, 3_000);
}

/// Like `tool_call_stub`, but prints the reply straight back out as the
/// `reply` field of a `system` event, so the test can read what actually
/// crossed the pipe rather than inferring it.
///
/// The reply is itself one line of JSON, so it is nested as a raw value
/// (`%s`, unquoted) rather than escaped into a string — that keeps the whole
/// envelope parseable in one pass on the way back.
const echo_reply_stub =
    "#!/bin/sh\n" ++
    tool_call_line ++ "\n" ++
    read_reply ++ "\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"reply\":%s}\\n' \"$reply\"\n" ++
    "exit 0\n";

/// Runs one `tools/call` whose handler returns `size` bytes, and hands back
/// the reply the child received, parsed. Caller owns the returned tree.
fn echoedReply(size: *usize) !std.json.Parsed(std.json.Value) {
    const servers = [_]agent.McpServer{.{
        .name = "s",
        .tools = &.{.{
            .name = "t",
            .description = "d",
            .handler = fillerHandler,
            .context = size,
        }},
    }};

    var stub = try Stub.init(echo_reply_stub);
    defer stub.deinit();

    const client = try stub.open(.{ .sdk_mcp_servers = &servers });
    defer _ = client.close();

    return echoedField(client, "reply");
}

/// Drains `client` to end of stream and hands back the value of `field` on
/// the first `system` event that carries one, re-parsed into a tree the
/// caller owns. The drain runs to the end even once the value is found, so
/// the stub reaches its own `exit` and `close` reaps a clean status.
fn echoedField(client: *agent.Client, field: []const u8) !std.json.Parsed(std.json.Value) {
    var echoed: ?std.json.Parsed(std.json.Value) = null;
    errdefer if (echoed) |*p| p.deinit();
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        if (echoed != null or e.kind != .system) continue;
        const value = e.parsed.value.object.get(field) orelse continue;
        // Re-parse into a tree the caller owns; `e.parsed` dies with the event.
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        var js: std.json.Stringify = .{ .writer = &buf.writer };
        try js.write(value);
        // `.alloc_always`, not the default: without it the tree borrows
        // `buf`, which the defer above frees at the end of this iteration,
        // and the caller would walk freed memory.
        echoed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            buf.written(),
            .{ .allocate = .alloc_always },
        );
    }
    return echoed orelse error.NothingEchoed;
}

/// The tool-call payload the child actually received, dug out of the nested
/// envelope `protocol.writeMcpResult` builds:
///
///   { response: { subtype, request_id, response: { mcp_response: { result } } } }
///
/// Note the two nested `response` levels: `beginControlResponse` opens the
/// outer one carrying `subtype` and `request_id`, and `beginMcpResponse` opens
/// an inner one around `mcp_response`.
///
/// Walked field by field rather than pattern-matched on the rendered text, so
/// a reply that came back malformed fails here instead of passing a substring
/// check against a string that happens to contain the right bytes.
fn replyText(root: std.json.Value) !struct { text: []const u8, is_error: bool } {
    const result = root.object.get("response").?
        .object.get("response").?
        .object.get("mcp_response").?
        .object.get("result").?;
    const content = result.object.get("content").?.array.items;
    return .{
        .text = content[0].object.get("text").?.string,
        .is_error = result.object.get("isError").?.bool,
    };
}

test "a tool result one byte over the cap arrives as an is_error explanation" {
    // The replacement is what the model sees, so it has to be an error result
    // carrying the reason rather than a silently truncated success.
    var size: usize = agent.max_tool_result_bytes + 1;
    var parsed = try echoedReply(&size);
    defer parsed.deinit();

    const reply = try replyText(parsed.value);
    try std.testing.expect(reply.is_error);
    try std.testing.expect(std.mem.indexOf(u8, reply.text, "tool result too long") != null);
    // The filler never reached the pipe at all.
    try std.testing.expect(std.mem.indexOf(u8, reply.text, "xxxxxxxxxx") == null);
}

test "a tool result of exactly the cap crosses the pipe intact" {
    // The bound has to admit what it advertises. A cap that truncated at its
    // own boundary would be a data-loss bug wearing a deadlock fix's clothes,
    // and only a real pipe proves the whole payload fits through one.
    var size: usize = agent.max_tool_result_bytes;
    var parsed = try echoedReply(&size);
    defer parsed.deinit();

    const reply = try replyText(parsed.value);
    try std.testing.expect(!reply.is_error);
    try std.testing.expectEqual(agent.max_tool_result_bytes, reply.text.len);
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOfNone(u8, reply.text, "x"),
    );
}

// --- lifecycle ---

test "a clean exit and a crash are reported differently" {
    // A CLI that dies on startup produces no events, so the read loop ends
    // exactly as it does for a healthy session. The exit status is the only
    // thing that distinguishes them, which makes reporting it correctly the
    // whole point of `wait`.
    var ok = try Stub.init(two_line_stub);
    defer ok.deinit();
    {
        const client = try ok.open(.{});
        defer _ = client.close();
        try std.testing.expectEqual(@as(usize, 2), try drain(client));
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try client.wait());
    }

    var crashed = try Stub.init(
        \\#!/bin/sh
        \\exit 7
        \\
    );
    defer crashed.deinit();
    {
        const client = try crashed.open(.{});
        defer _ = client.close();
        // Same shape as the healthy run from the reader's point of view.
        try std.testing.expectEqual(@as(usize, 0), try drain(client));
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try client.wait());
    }
}

test "the session id is captured from the first event carrying one" {
    // Null until an event supplies it, then fixed for the session: a later
    // event with a different id must not overwrite it, or a resumed session
    // would follow whichever line happened to arrive last.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\printf '{"type":"system","subtype":"init"}\n'
        \\printf '{"type":"assistant","session_id":"FIRST"}\n'
        \\printf '{"type":"result","session_id":"SECOND","result":"done"}\n'
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    // Nothing has been read, so nothing has supplied an id.
    try std.testing.expect(client.sessionId() == null);

    var e1 = (try client.next()).?;
    e1.deinit();
    // The first line carries no session_id, so it is still unset.
    try std.testing.expect(client.sessionId() == null);

    var e2 = (try client.next()).?;
    e2.deinit();
    try std.testing.expectEqualStrings("FIRST", client.sessionId().?);

    _ = try drain(client);
    try std.testing.expectEqualStrings("FIRST", client.sessionId().?);
}

test "wait is idempotent and close agrees with it" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\exit 3
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    const first = try client.wait();
    // The status is cached, so the second call cannot reap again — a second
    // wait4 on a reaped pid fails, and returning a different answer here would
    // mean it had been attempted.
    const second = try client.wait();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, first);
    try std.testing.expectEqual(first, second);
    // And `close` reports the same status rather than reaping a second time.
    try std.testing.expectEqual(first, client.close());
}

test "kill after a real reap does not overwrite the observed status" {
    // `kill` synthesizes `.signal = SIGTERM` because Zig 0.16's `Child.kill`
    // reaps internally and returns void, so it can never observe a status. A
    // `kill` arriving after the child has already been reaped must therefore
    // leave the real status alone, or a clean exit would be relabelled as a
    // signal death.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try client.wait());
    client.kill();
    // Still the observed value, and still not flagged as an assumption.
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try client.wait());
    try std.testing.expect(!client.killed);
}

test "send after closeStdin is refused rather than landing on a stale fd" {
    // `closeStdin` closes the descriptor, but `Io.File.Writer` holds the file
    // by value and keeps a stale copy of the number. The `stdin_closed` check
    // is what turns a late write into an error instead of a write into
    // whatever has since inherited the descriptor.
    var stub = try Stub.init(two_line_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try client.send("hello");
    client.closeStdin();
    try std.testing.expectError(error.StdinClosed, client.send("late"));
    try std.testing.expectError(error.StdinClosed, client.sendCommand("compact", ""));
    try std.testing.expectError(error.StdinClosed, client.interrupt());

    // `wait` closes stdin itself, so the same refusal holds after it.
    _ = try client.wait();
    try std.testing.expectError(error.StdinClosed, client.send("later"));
}

// --- framing over a real pipe ---

test "a final line with no trailing newline is still delivered" {
    // `printf` without the `\n`, so the stream ends mid-line and the delimiter
    // never arrives. The line still has to come out, or the last event of
    // every session that ends abruptly would be dropped.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\printf '{"type":"system","subtype":"init"}\n'
        \\printf '{"type":"result","result":"unterminated"}'
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    var e1 = (try client.next()).?;
    e1.deinit();

    var e2 = (try client.next()).?;
    defer e2.deinit();
    try std.testing.expectEqual(agent.Kind.result, e2.kind);
    try std.testing.expectEqualStrings("unterminated", e2.resultText().?);

    try std.testing.expect(try client.next() == null);
}

test "an oversized line costs one line and the stream resyncs" {
    // The tail of a rejected line stays queued in the reader. Left there it
    // would be read as the start of the next line and blow the same limit
    // again, wedging the session permanently. `readLine` discards through the
    // newline instead, so the error costs one line and the next one arrives.
    // Covered against a fixed buffer in src/client.zig; this is the same
    // property over a real pipe, where the bytes arrive in whatever chunks
    // the kernel hands over rather than all at once.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\printf '{"type":"system","subtype":"init"}\n'
        \\printf '{"type":"assistant","padding":"'
        \\i=0
        \\while [ $i -lt 40 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done
        \\printf '"}\n'
        \\printf '{"type":"result","result":"after"}\n'
        \\exit 0
        \\
    );
    defer stub.deinit();

    // Small enough that the padded line is rejected and the others are not.
    const client = try stub.open(.{ .max_line_bytes = 256 });
    defer _ = client.close();

    var e1 = (try client.next()).?;
    // Read before the deinit: `Event.deinit` sets the event to `undefined`.
    try std.testing.expectEqual(agent.Kind.system, e1.kind);
    e1.deinit();

    try std.testing.expectError(error.ProtocolTooLong, client.next());

    // What was read before the limit cut in is still there to log: a prefix
    // of the offending line, no longer than the budget, so a caller can tell
    // which event was dropped without the buffer having grown past the bound.
    const prefix = client.lastLine();
    try std.testing.expect(std.mem.startsWith(u8, prefix, "{\"type\":\"assistant\",\"padding\":\""));
    try std.testing.expect(prefix.len <= 256 + 1);

    // Resynced: the line after the oversized one is delivered normally.
    var e2 = (try client.next()).?;
    defer e2.deinit();
    try std.testing.expectEqualStrings("after", e2.resultText().?);
    try std.testing.expect(try client.next() == null);
}

test "a malformed line surfaces as InvalidJson without ending the stream" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\printf 'not json at all\n'
        \\printf '{"type":"result","result":"after"}\n'
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try std.testing.expectError(error.InvalidJson, client.next());
    var e = (try client.next()).?;
    defer e.deinit();
    try std.testing.expectEqualStrings("after", e.resultText().?);
}

test "open refuses a zero max_line_bytes before spawning anything" {
    // Rejected up front, so a misconfigured session costs no child. If it were
    // caught at the first read instead, the failure would look like a protocol
    // fault from the CLI rather than a configuration mistake — and there would
    // be a process to reap.
    var stub = try Stub.init(two_line_stub);
    defer stub.deinit();

    try std.testing.expectError(
        error.InvalidMaxLineBytes,
        stub.open(.{ .max_line_bytes = 0 }),
    );
}

// --- the write side, read back off a real pipe ---

/// Reads one line of the client's stdin and echoes it straight back out as the
/// `sent` field of a `system` event, then exits.
///
/// Covers the three public write methods, which are all `void` on success — so
/// a method emitting malformed JSON, or nothing, would otherwise pass.
///
/// `|| exit 0` bounds the read, as in `read_reply`. The echoed line is nested
/// raw (`%s`) because it is itself JSON. One read, not two: these tests set no
/// `sdk_mcp_servers`, so `open` writes nothing ahead of the line under test.
const echo_stdin_stub =
    "#!/bin/sh\n" ++
    "IFS= read -r sent || exit 0\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"sent\":%s}\\n' \"$sent\"\n" ++
    "exit 0\n";

/// Runs `write` against a child that echoes its stdin, and hands back the line
/// the child received, parsed. Caller owns the returned tree.
///
/// The write happens before any `next` call, so the line is already in the pipe
/// when the stub reads it — and the stub only prints after its `read` returns,
/// so an event arriving at all means the line was written, flushed and
/// newline-terminated on a real pipe.
fn echoedStdin(write: *const fn (*agent.Client) agent.WriteError!void) !std.json.Parsed(std.json.Value) {
    var stub = try Stub.init(echo_stdin_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try write(client);
    return echoedField(client, "sent");
}

/// The single text block of a user turn, walked field by field so a turn that
/// came back with the wrong envelope fails here rather than passing a
/// substring check against text that happens to contain the right bytes.
fn userTurnText(root: std.json.Value) ![]const u8 {
    try std.testing.expectEqualStrings("user", root.object.get("type").?.string);
    const message = root.object.get("message").?;
    try std.testing.expectEqualStrings("user", message.object.get("role").?.string);
    const content = message.object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    try std.testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    return content[0].object.get("text").?.string;
}

fn sendHello(client: *agent.Client) agent.WriteError!void {
    // Characters that must survive JSON escaping intact. A turn assembled by
    // concatenation rather than encoded would arrive with a bare quote and
    // fail to parse at all, which the walk above would catch as a hard error.
    return client.send("hello \"world\"\n\t done");
}

test "send writes a well-formed user turn the child can read back" {
    // The success path of `send` was never observed. It is called once
    // elsewhere in this suite and no stub reads what it wrote, so a `send`
    // emitting malformed JSON — or nothing — passed every test in the file.
    var parsed = try echoedStdin(sendHello);
    defer parsed.deinit();

    // The child parsed it: `printf '%s'` spliced the line into an envelope
    // that had to survive a second parse on the way back here.
    try std.testing.expectEqualStrings(
        "hello \"world\"\n\t done",
        try userTurnText(parsed.value),
    );
}

fn sendReview(client: *agent.Client) agent.WriteError!void {
    return client.sendCommand("code-review", "src/");
}

fn sendBareCommand(client: *agent.Client) agent.WriteError!void {
    return client.sendCommand("compact", "");
}

test "sendCommand writes the slash form as a user turn" {
    // `sendCommand` was covered only for `error.StdinClosed`, so its actual
    // output was never checked against a child. The text is assembled by
    // `writeCommandMessage` through `beginWriteRaw`, escaping the name and
    // arguments in pieces straight into the writer — a path with no unit test
    // downstream of a real pipe.
    var with_args = try echoedStdin(sendReview);
    defer with_args.deinit();
    try std.testing.expectEqualStrings("/code-review src/", try userTurnText(with_args.value));

    // Empty arguments write no separator, so the text is the bare command
    // rather than a name with a trailing space.
    var bare = try echoedStdin(sendBareCommand);
    defer bare.deinit();
    try std.testing.expectEqualStrings("/compact", try userTurnText(bare.value));
}

fn sendInterrupt(client: *agent.Client) agent.WriteError!void {
    return client.interrupt();
}

test "interrupt writes a control_request the child can read back" {
    // Also covered only for `error.StdinClosed` until now. Unlike the two
    // above this is a control_request, not a user turn, and it carries a
    // request_id the CLI matches its response to — a wrong shape here stalls
    // the CLI until its own timeout rather than failing visibly.
    var parsed = try echoedStdin(sendInterrupt);
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expectEqualStrings("control_request", root.object.get("type").?.string);
    const request = root.object.get("request").?;
    try std.testing.expectEqualStrings("interrupt", request.object.get("subtype").?.string);
    // The id is generated per client, so only its presence and shape are
    // fixed. `zig_1` because nothing else on this client wrote a line first.
    try std.testing.expectEqualStrings("zig_1", request.object.get("request_id").?.string);
}

// --- kill on a child that has not exited ---

/// A stub that stays alive without ever exiting on its own within the test's
/// window, so `kill` has a live child to signal.
///
/// Every other stub races to its own `exit`, exercising only the branch where
/// `kill` finds an already-reaped child. This one sleeps so `Child.kill`
/// signals a running process.
///
/// The sleep is a bounded lifetime, as in `no_read_stub`. `trap '' PIPE`
/// because `kill` closes stdin first, and the stub must not die of a signal
/// this test did not send.
const sleeping_stub =
    \\#!/bin/sh
    \\trap '' PIPE
    \\printf '{"type":"system","subtype":"init","session_id":"L1"}\n'
    \\sleep 3
    \\exit 0
    \\
;

test "kill terminates a child that has not exited on its own" {
    // The recovery path, against the only child in this suite that does not
    // reap itself first. `kill` here does real work: it signals a live process
    // and reaps it, rather than returning early because `term` was already set.
    var stub = try Stub.init(sleeping_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    // Read the one line the stub prints before it sleeps, so the child is
    // provably running — not merely spawned — when the kill lands.
    var e = (try client.next()).?;
    try std.testing.expectEqual(agent.Kind.system, e.kind);
    e.deinit();

    client.kill();

    // Synthesized, not observed: `Child.kill` reaps internally and returns
    // void, so SIGTERM is an assumption. `killed` is what marks it as one.
    try std.testing.expect(client.killed);
    try std.testing.expectEqual(
        std.process.Child.Term{ .signal = std.posix.SIG.TERM },
        try client.wait(),
    );

    // Reaching here at all is half the assertion: `wait` after `kill` answers
    // from the cache instead of reaping a second time, which would block on a
    // pid that no longer exists.
    try std.testing.expect(try client.next() == null);
}

test "closeStdin records a flush that failed against a dead child" {
    // The field only earns its place if `closeStdin` writes to it. The previous
    // version of this test assigned `flush_error` directly and read it back,
    // which passes whether or not `closeStdin` records anything at all.
    //
    // Driving a real child is what makes it a regression test, and the ordering
    // matters: `wait` closes stdin itself, so anything sent after it is refused
    // with `StdinClosed` and never reaches a flush. The child has to be gone
    // while stdin is still open, which a stub that exits immediately gives —
    // queue more than the 16 KiB writer buffer so the data is pushed to a pipe
    // whose reader is dead, then let `closeStdin` flush the remainder.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    // Drain to end of stream: the stub emits nothing and exits, so this returns
    // as soon as the child is gone, without closing stdin the way `wait` would.
    while (try client.next()) |event| {
        var e = event;
        e.deinit();
    }

    var sends: usize = 0;
    var send_error: ?anyerror = null;
    while (sends < 64) : (sends += 1) {
        client.send("x" ** 512) catch |err| {
            send_error = err;
            break;
        };
    }

    client.closeStdin();

    // Writing to a pipe with no reader must be reported somewhere: either the
    // send that pushed past the buffer saw it, or the closing flush did. A
    // silent success would mean a queued turn vanished with no signal, which is
    // exactly what this field exists to prevent.
    try std.testing.expect(client.flush_error != null or send_error != null);
}

// --- diagnostics: what `next` last saw ---

test "lastLine holds the bytes behind whatever next last reported" {
    // `error.InvalidJson` on its own says a line was bad, not which one, and
    // the line is gone by the time the caller could ask. `lastLine` is what
    // makes the error actionable: it holds the raw bytes until the next read,
    // for every outcome of `next`, not only the failing ones.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\printf 'not json at all\n'
        \\printf '{"type":"result","result":"after"}\n'
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    // Nothing has been read, so there is nothing to show.
    try std.testing.expectEqual(@as(usize, 0), client.lastLine().len);

    try std.testing.expectError(error.InvalidJson, client.next());
    try std.testing.expectEqualStrings("not json at all", client.lastLine());

    // A delivered event is backed by its line too, newline stripped.
    var e = (try client.next()).?;
    defer e.deinit();
    try std.testing.expectEqualStrings("after", e.resultText().?);
    try std.testing.expectEqualStrings("{\"type\":\"result\",\"result\":\"after\"}", client.lastLine());

    // End of stream leaves nothing behind, so a stale line cannot be
    // mistaken for the reason the stream ended.
    try std.testing.expect(try client.next() == null);
    try std.testing.expectEqual(@as(usize, 0), client.lastLine().len);
}

// --- open-time validation ---

test "open refuses a tool schema that is not a JSON object before spawning" {
    // The schema is spliced into the `tools/list` reply raw, so a malformed
    // one corrupts the handshake frame rather than failing a call. The path
    // names a binary that does not exist: spawning it fails with its own
    // error, so getting `InvalidToolSchema` proves the check ran first and
    // no child was ever started for a session that could not work.
    const missing_binary = "/nonexistent/claude";
    const rejected = [_][]const u8{
        "not json",
        "{\"type\":\"object\"",
        "[]",
        "\"{}\"",
        "42",
        "",
    };
    for (rejected) |schema| {
        const tools = [_]agent.Tool{.{
            .name = "t",
            .description = "d",
            .input_schema = schema,
            .handler = recordingHandler,
        }};
        const servers = [_]agent.McpServer{.{ .name = "s", .tools = &tools }};
        try std.testing.expectError(error.InvalidToolSchema, agent.Client.open(gpa, io, .{
            .claude_path = missing_binary,
            .sdk_mcp_servers = &servers,
        }));
    }

    // An object passes, leading whitespace included, and so does the default
    // schema a `Tool` carries when none is given — each reaches the spawn,
    // which is where a missing binary is reported.
    const accepted = [_]agent.Tool{
        .{ .name = "spaced", .description = "d", .input_schema = "  {\"type\":\"object\"}", .handler = recordingHandler },
        .{ .name = "default", .description = "d", .handler = recordingHandler },
    };
    for (accepted) |tool| {
        const tools = [_]agent.Tool{tool};
        const servers = [_]agent.McpServer{.{ .name = "s", .tools = &tools }};
        try std.testing.expectError(error.FileNotFound, agent.Client.open(gpa, io, .{
            .claude_path = missing_binary,
            .sdk_mcp_servers = &servers,
        }));
    }
}

// --- the CLI answering this client's own requests ---

/// A stub that answers the `initialize` request `open` sends as `zig_1`
/// with an error, then carries on with a normal line. `open` writes the
/// request before returning, so by the time the stub's first line is read the
/// request it refuses has already been sent.
const rejecting_initialize_stub =
    \\#!/bin/sh
    \\trap '' PIPE
    \\printf '{"type":"control_response","response":{"subtype":"error","request_id":"zig_1","error":"sdkMcpServers rejected"}}\n'
    \\printf '{"type":"result","result":"after"}\n'
    \\exit 0
    \\
;

test "a rejected initialize surfaces from next with the CLI's text" {
    // Without this the first symptom of a refused handshake is the model
    // reporting it cannot find a tool, several turns later. The refusal has
    // to come out of `next` as an error, with the CLI's own text attached,
    // and the stream has to survive the report.
    const servers = [_]agent.McpServer{.{ .name = "s" }};

    var stub = try Stub.init(rejecting_initialize_stub);
    defer stub.deinit();

    const client = try stub.open(.{ .sdk_mcp_servers = &servers });
    defer _ = client.close();

    try std.testing.expect(client.lastControlError() == null);
    try std.testing.expectError(error.ControlRequestRejected, client.next());
    try std.testing.expectEqualStrings("sdkMcpServers rejected", client.lastControlError().?);

    // The stream is intact past the error, and the text stays readable until
    // `close` rather than dying with the event that carried it.
    var e = (try client.next()).?;
    defer e.deinit();
    try std.testing.expectEqualStrings("after", e.resultText().?);
    try std.testing.expect(try client.next() == null);
    try std.testing.expectEqualStrings("sdkMcpServers rejected", client.lastControlError().?);
}

test "a successful control_response is consumed without surfacing" {
    // The normal handshake: the CLI accepts `initialize`, and the caller sees
    // nothing of it. A success that leaked out as an event would be an
    // `unknown`-kind line every tool-bearing session had to skip.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\trap '' PIPE
        \\printf '{"type":"control_response","response":{"subtype":"success","request_id":"zig_1","response":{}}}\n'
        \\printf '{"type":"result","result":"after"}\n'
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{ .skills = &.{} });
    defer _ = client.close();

    try std.testing.expectEqual(@as(usize, 1), try drain(client));
    try std.testing.expect(client.lastControlError() == null);
}

// --- permission prompts over a real pipe ---

/// The `can_use_tool` request the CLI sends when a call is not already
/// pre-authorized, as one line. `p1` is the id the reply must carry back.
const permission_request_line =
    \\printf '{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}\n'
;

/// Issues one permission prompt, reads the decision back, and echoes it as
/// the `reply` field of a `system` event, like `echo_reply_stub`.
///
/// Two reads, in this order: a handler makes `open` send `initialize` before
/// anything else (the CLI routes prompts to a host that opened with the
/// handshake), so the first line on stdin is that request and the decision is
/// the second. A stub that read once would consume the handshake and EPIPE
/// the decision, which is exactly how this test fails when the rule regresses.
const echo_permission_stub =
    "#!/bin/sh\n" ++
    permission_request_line ++ "\n" ++
    read_reply ++ "\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"reply\":%s}\\n' \"$reply\"\n" ++
    "exit 0\n";

/// The same prompt against a session with no handler. No handler means no
/// handshake, so there is exactly one line to read: the error reply.
const echo_permission_stub_unhandled =
    "#!/bin/sh\n" ++
    permission_request_line ++ "\n" ++
    "IFS= read -r reply || exit 0\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"reply\":%s}\\n' \"$reply\"\n" ++
    "exit 0\n";

/// What the permission handler was asked, and what it should answer.
const PermissionRecord = struct {
    decision: agent.PermissionDecision,
    calls: usize = 0,
    /// Whether the request arrived with the tool name and input the stub
    /// sent, so the test proves the payload crossed the pipe rather than the
    /// handler merely firing.
    saw_bash: bool = false,
    saw_ls: bool = false,
};

fn recordingPermissionHandler(
    context: ?*anyopaque,
    arena: std.mem.Allocator,
    tool_name: []const u8,
    input: std.json.Value,
) anyerror!agent.PermissionDecision {
    _ = arena;
    const record: *PermissionRecord = @ptrCast(@alignCast(context.?));
    record.calls += 1;
    record.saw_bash = std.mem.eql(u8, tool_name, "Bash");
    if (input == .object) {
        if (input.object.get("command")) |command| {
            if (command == .string) record.saw_ls = std.mem.eql(u8, command.string, "ls");
        }
    }
    return record.decision;
}

/// Runs one permission prompt through `record`'s decision and hands back the
/// reply the child received, parsed. Caller owns the returned tree.
fn echoedPermissionReply(record: *PermissionRecord) !std.json.Parsed(std.json.Value) {
    var stub = try Stub.init(echo_permission_stub);
    defer stub.deinit();

    const client = try stub.open(.{
        .permission_handler = recordingPermissionHandler,
        .permission_context = record,
    });
    defer _ = client.close();

    return echoedField(client, "reply");
}

/// The decision object the child received, dug out of the envelope the
/// permission writers build:
///
///   { type, response: { subtype, request_id, response: { behavior, ... } } }
///
/// The outer fields are checked on the way in: a reply under the wrong id, or
/// not marked `success`, is one the CLI would discard, whatever it carries.
fn permissionDecision(root: std.json.Value) !std.json.Value {
    try std.testing.expectEqualStrings("control_response", root.object.get("type").?.string);
    const outer = root.object.get("response").?;
    try std.testing.expectEqualStrings("success", outer.object.get("subtype").?.string);
    try std.testing.expectEqualStrings("p1", outer.object.get("request_id").?.string);
    return outer.object.get("response").?;
}

test "a permission allow echoes the proposed input back to the child" {
    // The official SDKs answer with `behavior` plus `updatedInput`, and the
    // CLI runs the tool with whatever `updatedInput` says — so a plain allow
    // has to carry the input back unchanged, not omit it.
    var record: PermissionRecord = .{ .decision = .allow };
    var parsed = try echoedPermissionReply(&record);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), record.calls);
    try std.testing.expect(record.saw_bash);
    try std.testing.expect(record.saw_ls);

    const decision = try permissionDecision(parsed.value);
    try std.testing.expectEqualStrings("allow", decision.object.get("behavior").?.string);
    const input = decision.object.get("updatedInput").?;
    try std.testing.expectEqual(@as(usize, 1), input.object.count());
    try std.testing.expectEqualStrings("ls", input.object.get("command").?.string);
    try std.testing.expect(decision.object.get("message") == null);
}

test "a permission allow_with_input replaces the input the child runs with" {
    var record: PermissionRecord = .{ .decision = .{ .allow_with_input = "{\"command\":\"ls -la\"}" } };
    var parsed = try echoedPermissionReply(&record);
    defer parsed.deinit();

    const decision = try permissionDecision(parsed.value);
    try std.testing.expectEqualStrings("allow", decision.object.get("behavior").?.string);
    // The handler's object, spliced raw, survived a parse on the child's
    // side and another on the way back here.
    const input = decision.object.get("updatedInput").?;
    try std.testing.expectEqualStrings("ls -la", input.object.get("command").?.string);
}

test "a permission deny carries the message the model will read" {
    var record: PermissionRecord = .{ .decision = .{ .deny = "use Read instead" } };
    var parsed = try echoedPermissionReply(&record);
    defer parsed.deinit();

    const decision = try permissionDecision(parsed.value);
    try std.testing.expectEqualStrings("deny", decision.object.get("behavior").?.string);
    try std.testing.expectEqualStrings("use Read instead", decision.object.get("message").?.string);
    // A deny proposes nothing to run, so there is no input to carry.
    try std.testing.expect(decision.object.get("updatedInput") == null);
}

test "a permission prompt with no handler is refused, not left unanswered" {
    // The CLI only routes prompts here when asked, but a flag is not a
    // promise. Whatever arrives has to be answered: an unanswered control
    // request leaves the CLI blocked until its own timeout, which reads as a
    // hung session rather than a configuration mistake.
    var stub = try Stub.init(echo_permission_stub_unhandled);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    var parsed = try echoedField(client, "reply");
    defer parsed.deinit();

    const outer = parsed.value.object.get("response").?;
    try std.testing.expectEqualStrings("error", outer.object.get("subtype").?.string);
    try std.testing.expectEqualStrings("p1", outer.object.get("request_id").?.string);
    try std.testing.expectEqualStrings("unsupported control request", outer.object.get("error").?.string);
}

// --- allocation failure ---

test "an allocation failure inside next is OutOfMemory, and close still frees everything" {
    // Every allocation on the path from `open` through the first event,
    // failed one at a time. The counts come from a first pass that never
    // fails, so the sweep tracks the code rather than a number that goes
    // stale when a std.json internal adds or drops an allocation. Each pass
    // spawns a fresh stub, since the one before it was reaped.
    //
    // `std.testing.allocator` backs the failing allocator, so a client that
    // leaked on the way out — a parsed tree not freed when the session-id
    // dupe failed, say — fails the test as a leak on top of the count check.
    var stub = try Stub.init(two_line_stub);
    defer stub.deinit();

    var during_open: usize = 0;
    var during_next: usize = 0;
    {
        var counting = std.testing.FailingAllocator.init(gpa, .{});
        const client = try agent.Client.open(counting.allocator(), io, .{ .claude_path = stub.path });
        during_open = counting.allocations;
        var event = (try client.next()).?;
        event.deinit();
        during_next = counting.allocations - during_open;
        _ = client.close();
        try std.testing.expectEqual(counting.allocations, counting.deallocations);
    }
    // Both halves allocate, or the sweeps below would be empty and prove
    // nothing.
    try std.testing.expect(during_open > 0);
    try std.testing.expect(during_next > 0);

    // A failure during `open` is reported from `open`, with nothing left
    // behind: no client, and no child to reap.
    var fail_index: usize = 0;
    while (fail_index < during_open) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, agent.Client.open(
            failing.allocator(),
            io,
            .{ .claude_path = stub.path },
        ));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
    }

    // A failure during `next` — the line buffer growing, the JSON parse, or
    // the session-id dupe — is `OutOfMemory` from `next`, and `close` then
    // frees whatever the failing path had already taken.
    while (fail_index < during_open + during_next) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const client = try agent.Client.open(failing.allocator(), io, .{ .claude_path = stub.path });
        try std.testing.expectError(error.OutOfMemory, client.next());
        try std.testing.expect(failing.has_induced_failure);
        _ = client.close();
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
    }
}
