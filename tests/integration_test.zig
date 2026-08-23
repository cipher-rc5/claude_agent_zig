// tests/integration_test.zig
// End-to-end tests that drive the real `Client` against scripted stub CLIs.
//
// Everything else in the suite stops at the module boundary: `readLine` is
// fed a fixed buffer, `serveControlRequest` writes into `reply_override`, and
// no test anywhere spawns a process. That leaves the whole of `open`, `next`,
// `wait`, `kill`, and `close` — the process lifecycle and the read loop over a
// real pipe — covered only by inspection. These tests close that gap.
//
// The stub is a `#!/bin/sh` script written to a temp dir at runtime and
// pointed at by `Options.claude_path`. Three properties make that work:
//
//   * `buildArgv` prepends the real CLI flags before anything the test
//     controls, and a shell script that only prints ignores its arguments, so
//     the flags are harmless. (Passing `/bin/sh -c '...'` via `extra_args`
//     does NOT work for the same reason inverted: `extra_args` lands last, so
//     `sh` would see `--print --input-format ...` first and reject them.)
//   * Writing the script at runtime rather than committing it under tests/
//     means no assumption about the cwd `zig build test` runs in, and no
//     executable checked into the repository.
//   * Every stub terminates on its own — each one is a fixed number of
//     `printf` calls and an `exit`. Nothing here can block forever waiting on
//     a child that never finishes, which matters because this suite runs in
//     `just ci` on every push.

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
/// Both reads are mandatory and in this order. `Options.needsInitialize` is
/// true whenever `sdk_mcp_servers` is set, so `open` writes an `initialize`
/// control request into the child's stdin before the test has read a single
/// event. A stub that reads once gets *that* line, then exits and closes the
/// pipe while this client is still writing the tool reply — which surfaces as
/// `error.WriteFailed` from EPIPE, not as the property under test.
///
/// `|| exit 0` on each read is the bounded-lifetime guard. If a reply never
/// comes the client has closed stdin, so `read` hits end of file and returns
/// non-zero rather than blocking; the stub exits and the test fails on a
/// missing event instead of hanging. Nothing here can wait forever, which is
/// what makes this suite safe to run in `just ci`.
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
/// This is the shape the bound actually exists for. `next` is the only reader
/// of the child's stdout, so while it is writing a tool reply nobody is
/// draining the child's stdin — and here the child never drains it either.
/// The whole reply, `initialize` request included, has to fit in the pipe's
/// buffer unread, or the write blocks forever with no one left to unblock it.
///
/// It emits its remaining output first so the events are already queued, then
/// sleeps to stay alive across the write, then exits.
///
/// The sleep is load-bearing but is NOT a synchronization primitive. It is a
/// bounded lifetime: whether or not the write has landed when it expires, the
/// stub exits and the test terminates, so this can never hang `just ci`.
/// Without it the stub exits immediately and the reply write fails with EPIPE
/// before the bound is ever exercised — verified by deleting it, which fails
/// this test on every run.
///
/// 0.2s rather than the ~0.05s that measurably suffices here: the margin is
/// for a loaded CI machine, and it is spent only in this one test. It bounds
/// the wait; it does not bound the suite, which finishes well before it.
const no_read_stub =
    "#!/bin/sh\n" ++
    tool_call_line ++ "\n" ++
    "printf '{\"type\":\"result\",\"result\":\"done\"}\\n'\n" ++
    "sleep 0.2\n" ++
    "exit 0\n";

test "an oversized tool result fits the pipe even when the child never reads" {
    // THE REGRESSION, in the configuration that makes it bite. `next` is the
    // only reader of the child's stdout, so a reply larger than the stdin pipe
    // blocks it in `writev` while the child blocks writing the stdout nobody is
    // left to read. Neither side moves again, the caller's thread is inside
    // `next`, and `kill` is unreachable — a permanent hang.
    //
    // The stub above never reads its stdin, so nothing drains the reply on the
    // far side and the bound is the only thing keeping the write non-blocking.
    // A 4 MiB handler result — the size the original deadlock was reproduced
    // with — is replaced by a short `is_error` payload that fits in one pipe
    // load, so `next` completes and the session finishes.
    //
    // Deliberately far above the cap rather than one byte over: a payload just
    // past the bound still fits a 64 KiB pipe and would pass either way, which
    // would make this test decorative. `tool result one byte over the cap`
    // below covers the boundary itself.
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

    var stub = try Stub.init(no_read_stub);
    defer stub.deinit();

    const client = try stub.open(.{ .sdk_mcp_servers = &servers });
    defer _ = client.close();

    // Reaching this at all is the assertion: the dispatch inside `next`
    // wrote the reply without blocking, so the drain ran to end of stream.
    try std.testing.expectEqual(@as(usize, 1), try drain(client));
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

    var echoed: ?std.json.Parsed(std.json.Value) = null;
    errdefer if (echoed) |*p| p.deinit();
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        if (e.kind != .system) continue;
        const reply = e.parsed.value.object.get("reply") orelse continue;
        // Re-parse into a tree the caller owns; `e.parsed` dies with the event.
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        var js: std.json.Stringify = .{ .writer = &buf.writer };
        try js.write(reply);
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
    return echoed orelse error.NoReplyEchoed;
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
