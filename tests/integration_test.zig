// tests/integration_test.zig
// Client integration tests with temporary shell stubs and real pipes.

const std = @import("std");
const agent = @import("agent");

const io = std.testing.io;
const gpa = std.testing.allocator;

// Temporary CLI script, removed by `deinit`.
const Stub = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    // Absolute path keeps spawning independent of PATH and cwd.
    fn init(script: []const u8) !Stub {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        try tmp.dir.writeFile(io, .{
            .sub_path = "stub.sh",
            .data = script,
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

// Counts and frees events; control traffic is handled internally.
fn drain(client: *agent.Client) !usize {
    var count: usize = 0;
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        count += 1;
    }
    return count;
}

// Ignore SIGPIPE so early closure preserves the intended exit status.
const two_line_stub =
    \\#!/bin/sh
    \\trap '' PIPE
    \\printf '{"type":"system","subtype":"init","session_id":"S1"}\n'
    \\printf '{"type":"result","result":"done"}\n'
    \\exit 0
    \\
;

// --- reads after reaping ---

test "next after wait reports end of stream instead of reading a stale fd" {
    var stub = try Stub.init(two_line_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try std.testing.expectEqual(@as(usize, 2), try drain(client));
    _ = try client.wait();

    try std.testing.expect(try client.next() == null);
    try std.testing.expect(try client.next() == null);
}

test "next after kill also reports end of stream" {
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

// --- tool reply limits ---

fn fillerHandler(context: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) anyerror!agent.ToolResult {
    _ = arguments;
    const size: *const usize = @ptrCast(@alignCast(context.?));
    const text = try arena.alloc(u8, size.*);
    @memset(text, 'x');
    return .{ .text = text };
}

const CallRecord = struct {
    ran: bool = false,
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

const tool_call_line =
    \\printf '{"type":"control_request","request_id":"c1","request":{"subtype":"mcp_message","server_name":"s","message":{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"t","arguments":{"n":41}}}}}\n'
;

// Consume initialization before reading the tool reply.
const read_reply =
    \\IFS= read -r init_line || exit 0
    \\IFS= read -r reply || exit 0
;

// Reading a reply line proves flush and newline framing.
const tool_call_stub =
    "#!/bin/sh\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"T1\"}\\n'\n" ++
    tool_call_line ++ "\n" ++
    read_reply ++ "\n" ++
    "printf '{\"type\":\"result\",\"result\":\"replied\"}\\n'\n" ++
    "exit 0\n";

test "a tools/call from the child runs the handler and the reply reaches the child" {
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

    try std.testing.expectEqual(@as(usize, 2), try drain(client));

    try std.testing.expect(record.ran);
    try std.testing.expectEqual(@as(i64, 41), record.n);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try client.wait());
}

// Refuse stdin to expose reply deadlocks; exec makes the pipe owner signalable.
const no_read_stub =
    "#!/bin/sh\n" ++
    tool_call_line ++ "\n" ++
    "printf '{\"type\":\"result\",\"result\":\"done\"}\\n'\n" ++
    "exec sleep 5\n";

// Threaded cancellation unblocks body syscalls on deadline.
fn underDeadline(comptime body: fn () bool, millis: i64) !void {
    const Race = union(enum) { body: bool, deadline: void };

    const tasks = struct {
        fn run() bool {
            return body();
        }
        fn timer(ms: i64) void {
            io.sleep(.fromMilliseconds(ms), .awake) catch {};
        }
    };

    var buf: [2]Race = undefined;
    var race: std.Io.Select(Race) = .init(io, &buf);
    try race.concurrent(.body, tasks.run, .{});
    try race.concurrent(.deadline, tasks.timer, .{millis});

    const first = try race.await();
    race.cancelDiscard();

    switch (first) {
        .body => |ok| try std.testing.expect(ok),
        .deadline => return error.DeadlineExceeded,
    }
}

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

    var event = (client.next() catch return false) orelse return false;
    const ok = event.kind == .result;
    event.deinit();

    client.kill();
    return ok;
}

test "an oversized tool result fits the pipe even when the child never reads" {
    // Exceed pipe capacity so a missing reply cap becomes a deadline failure.
    try underDeadline(oversizedToolResultFitsPipe, 3_000);
}

// Echo raw JSON so assertions inspect the actual wire reply.
const echo_reply_stub =
    "#!/bin/sh\n" ++
    tool_call_line ++ "\n" ++
    read_reply ++ "\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"reply\":%s}\\n' \"$reply\"\n" ++
    "exit 0\n";

// Caller owns the parsed wire reply.
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

// Copy `field` from the first matching system event; drain to let the stub exit.
fn echoedField(client: *agent.Client, field: []const u8) !std.json.Parsed(std.json.Value) {
    var echoed: ?std.json.Parsed(std.json.Value) = null;
    errdefer if (echoed) |*p| p.deinit();
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        if (echoed != null or e.kind != .system) continue;
        const value = e.parsed.value.object.get(field) orelse continue;
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        var js: std.json.Stringify = .{ .writer = &buf.writer };
        try js.write(value);
        // Copy parsed data because `buf` is freed after this iteration.
        echoed = try std.json.parseFromSlice(
            std.json.Value,
            gpa,
            buf.written(),
            .{ .allocate = .alloc_always },
        );
    }
    return echoed orelse error.NothingEchoed;
}

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
    var size: usize = agent.max_tool_result_bytes + 1;
    var parsed = try echoedReply(&size);
    defer parsed.deinit();

    const reply = try replyText(parsed.value);
    try std.testing.expect(reply.is_error);
    try std.testing.expect(std.mem.indexOf(u8, reply.text, "tool result too long") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply.text, "xxxxxxxxxx") == null);
}

test "a tool result of exactly the cap crosses the pipe intact" {
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
        try std.testing.expectEqual(@as(usize, 0), try drain(client));
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try client.wait());
    }
}

test "the session id is captured from the first event carrying one" {
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

    try std.testing.expect(client.sessionId() == null);

    var e1 = (try client.next()).?;
    e1.deinit();
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
    const second = try client.wait();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, first);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first, client.close());
}

test "kill after a real reap does not overwrite the observed status" {
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
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try client.wait());
    try std.testing.expect(!client.killed);
}

test "send after closeStdin is refused rather than landing on a stale fd" {
    var stub = try Stub.init(two_line_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try client.send("hello");
    client.closeStdin();
    try std.testing.expectError(error.StdinClosed, client.send("late"));
    try std.testing.expectError(error.StdinClosed, client.sendCommand("compact", ""));
    try std.testing.expectError(error.StdinClosed, client.interrupt());

    _ = try client.wait();
    try std.testing.expectError(error.StdinClosed, client.send("later"));
}

// --- framing over a real pipe ---

test "a final line with no trailing newline is still delivered" {
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

    const client = try stub.open(.{ .max_line_bytes = 256 });
    defer _ = client.close();

    var e1 = (try client.next()).?;
    try std.testing.expectEqual(agent.Kind.system, e1.kind);
    e1.deinit();

    try std.testing.expectError(error.ProtocolTooLong, client.next());

    const prefix = client.lastLine();
    try std.testing.expect(std.mem.startsWith(u8, prefix, "{\"type\":\"assistant\",\"padding\":\""));
    try std.testing.expect(prefix.len <= 256 + 1);

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
    var stub = try Stub.init(two_line_stub);
    defer stub.deinit();

    try std.testing.expectError(
        error.InvalidMaxLineBytes,
        stub.open(.{ .max_line_bytes = 0 }),
    );
}

// --- write framing ---

// No handshake: the first stdin line is the write under test.
const echo_stdin_stub =
    "#!/bin/sh\n" ++
    "IFS= read -r sent || exit 0\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"sent\":%s}\\n' \"$sent\"\n" ++
    "exit 0\n";

// Caller owns the parsed echo; readback proves flush and framing.
fn echoedStdin(write: *const fn (*agent.Client) agent.WriteError!void) !std.json.Parsed(std.json.Value) {
    var stub = try Stub.init(echo_stdin_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    try write(client);
    return echoedField(client, "sent");
}

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
    return client.send("hello \"world\"\n\t done");
}

test "send writes a well-formed user turn the child can read back" {
    var parsed = try echoedStdin(sendHello);
    defer parsed.deinit();

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
    var with_args = try echoedStdin(sendReview);
    defer with_args.deinit();
    try std.testing.expectEqualStrings("/code-review src/", try userTurnText(with_args.value));

    var bare = try echoedStdin(sendBareCommand);
    defer bare.deinit();
    try std.testing.expectEqualStrings("/compact", try userTurnText(bare.value));
}

fn sendInterrupt(client: *agent.Client) agent.WriteError!void {
    return client.interrupt();
}

test "initialize writes its correlation ID at the top level of the real pipe frame" {
    var stub = try Stub.init(echo_stdin_stub);
    defer stub.deinit();
    const client = try stub.open(.{ .skills = &.{} });
    defer _ = client.close();
    var parsed = try echoedField(client, "sent");
    defer parsed.deinit();
    const envelope = parsed.value.object;
    try std.testing.expectEqualStrings("control_request", envelope.get("type").?.string);
    try std.testing.expectEqualStrings("zig_1", envelope.get("request_id").?.string);
    const request = envelope.get("request").?.object;
    try std.testing.expectEqualStrings("initialize", request.get("subtype").?.string);
    try std.testing.expect(!request.contains("request_id"));
}

test "interrupt writes a control_request the child can read back" {
    var parsed = try echoedStdin(sendInterrupt);
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expectEqualStrings("control_request", root.object.get("type").?.string);
    const request = root.object.get("request").?;
    try std.testing.expectEqualStrings("interrupt", request.object.get("subtype").?.string);
    try std.testing.expectEqualStrings("zig_1", root.object.get("request_id").?.string);
    try std.testing.expect(!request.object.contains("request_id"));
}

// --- running-child termination ---

// Bound orphan lifetime and ignore SIGPIPE to preserve the intended signal.
const sleeping_stub =
    \\#!/bin/sh
    \\trap '' PIPE
    \\printf '{"type":"system","subtype":"init","session_id":"L1"}\n'
    \\sleep 3
    \\exit 0
    \\
;

test "kill terminates a child that has not exited on its own" {
    var stub = try Stub.init(sleeping_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    var e = (try client.next()).?;
    try std.testing.expectEqual(agent.Kind.system, e.kind);
    e.deinit();

    client.kill();

    try std.testing.expect(client.killed);
    try std.testing.expectEqual(
        std.process.Child.Term{ .signal = std.posix.SIG.TERM },
        try client.wait(),
    );

    try std.testing.expect(try client.next() == null);
}

test "closeStdin records a flush that failed against a dead child" {
    // Preserve stdin past child exit to exercise broken-pipe writes and final flush.
    var stub = try Stub.init(
        \\#!/bin/sh
        \\exit 0
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    while (try client.next()) |event| {
        var e = event;
        e.deinit();
    }

    var sends: usize = 0;
    var send_error: ?anyerror = null;
    while (sends < 64) : (sends += 1) {
        client.send(&@as([512]u8, @splat('x'))) catch |err| {
            send_error = err;
            break;
        };
    }

    client.closeStdin();

    try std.testing.expect(client.flush_error != null or send_error != null);
}

// --- read diagnostics ---

test "lastLine holds the bytes behind whatever next last reported" {
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

    try std.testing.expectEqual(@as(usize, 0), client.lastLine().len);

    try std.testing.expectError(error.InvalidJson, client.next());
    try std.testing.expectEqualStrings("not json at all", client.lastLine());

    var e = (try client.next()).?;
    defer e.deinit();
    try std.testing.expectEqualStrings("after", e.resultText().?);
    try std.testing.expectEqualStrings("{\"type\":\"result\",\"result\":\"after\"}", client.lastLine());

    try std.testing.expect(try client.next() == null);
    try std.testing.expectEqual(@as(usize, 0), client.lastLine().len);
}

// --- open-time validation ---

test "open refuses a tool schema that is not a JSON object before spawning" {
    // A nonexistent binary proves invalid schemas are rejected before spawning.
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

// --- control responses ---

const rejecting_initialize_stub =
    \\#!/bin/sh
    \\trap '' PIPE
    \\printf '{"type":"control_response","response":{"subtype":"error","request_id":"zig_1","error":"sdkMcpServers rejected"}}\n'
    \\printf '{"type":"result","result":"after"}\n'
    \\exit 0
    \\
;

test "a rejected initialize surfaces from next with the CLI's text" {
    const servers = [_]agent.McpServer{.{ .name = "s" }};

    var stub = try Stub.init(rejecting_initialize_stub);
    defer stub.deinit();

    const client = try stub.open(.{ .sdk_mcp_servers = &servers });
    defer _ = client.close();

    try std.testing.expect(client.lastControlError() == null);
    try std.testing.expectError(error.InitializationRejected, client.next());
    try std.testing.expectEqualStrings("sdkMcpServers rejected", client.lastControlError().?);

    var e = (try client.next()).?;
    defer e.deinit();
    try std.testing.expectEqualStrings("after", e.resultText().?);
    try std.testing.expect(try client.next() == null);
    try std.testing.expectEqualStrings("sdkMcpServers rejected", client.lastControlError().?);
}

test "a successful control_response is consumed without surfacing" {
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

const permission_request_line =
    \\printf '{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}\n'
;

// Consume the handler-triggered handshake before echoing its decision.
const echo_permission_stub =
    "#!/bin/sh\n" ++
    permission_request_line ++ "\n" ++
    read_reply ++ "\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"reply\":%s}\\n' \"$reply\"\n" ++
    "exit 0\n";

// No handler means no handshake; the first line is the error reply.
const echo_permission_stub_unhandled =
    "#!/bin/sh\n" ++
    permission_request_line ++ "\n" ++
    "IFS= read -r reply || exit 0\n" ++
    "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"reply\":%s}\\n' \"$reply\"\n" ++
    "exit 0\n";

const PermissionRecord = struct {
    decision: agent.PermissionDecision,
    calls: usize = 0,
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

// Caller owns the parsed permission reply.
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

fn permissionDecision(root: std.json.Value) !std.json.Value {
    try std.testing.expectEqualStrings("control_response", root.object.get("type").?.string);
    const outer = root.object.get("response").?;
    try std.testing.expectEqualStrings("success", outer.object.get("subtype").?.string);
    try std.testing.expectEqualStrings("p1", outer.object.get("request_id").?.string);
    return outer.object.get("response").?;
}

test "a permission allow echoes the proposed input back to the child" {
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
    try std.testing.expect(decision.object.get("updatedInput") == null);
}

test "a permission prompt with no handler is refused, not left unanswered" {
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
    try std.testing.expect(during_open > 0);
    try std.testing.expect(during_next > 0);

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

    // Pipe fragmentation changes allocations; sweep until `next` succeeds.
    var next_failures: usize = 0;
    for (0..64) |offset| {
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        const client = try agent.Client.open(failing.allocator(), io, .{ .claude_path = stub.path });
        failing.fail_index = failing.allocations + offset;
        const result = client.next();
        if (result) |event| {
            var e = event.?;
            e.deinit();
            _ = client.close();
            try std.testing.expectEqual(failing.allocations, failing.deallocations);
            break;
        } else |err| {
            _ = client.close();
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(failing.allocations, failing.deallocations);
            next_failures += 1;
        }
    } else return error.AllocationSweepDidNotComplete;
    try std.testing.expect(next_failures > 0);
}

// --- independent clients ---

// Doubling `n` exposes replies crossing between clients.
fn doublingHandler(_: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) anyerror!agent.ToolResult {
    const n = arguments.object.get("n").?.integer;
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{n * 2}) };
}

// Each thread owns its session, child, stub, and borrowed server array.
const Session = struct {
    session_id: [16]u8 = undefined,
    session_id_len: usize = 0,
    doubled: [16]u8 = undefined,
    doubled_len: usize = 0,
    err: ?anyerror = null,

    fn run(session: *Session, id: []const u8) void {
        session.body(id) catch |e| {
            session.err = e;
        };
    }

    fn body(session: *Session, id: []const u8) !void {
        const servers = [_]agent.McpServer{.{
            .name = "s",
            .tools = &.{.{
                .name = "t",
                .description = "d",
                .handler = doublingHandler,
            }},
        }};

        const script = try std.mem.concat(gpa, u8, &.{
            "#!/bin/sh\n" ++
                "trap '' PIPE\n" ++
                "printf '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"",
            id,
            "\"}\\n'\n" ++
                tool_call_line ++ "\n" ++
                read_reply ++ "\n" ++
                "printf '{\"type\":\"system\",\"subtype\":\"echo\",\"reply\":%s}\\n' \"$reply\"\n" ++
                "exit 0\n",
        });
        defer gpa.free(script);

        var stub = try Stub.init(script);
        defer stub.deinit();

        const client = try stub.open(.{ .sdk_mcp_servers = &servers });
        defer _ = client.close();

        var parsed = try echoedField(client, "reply");
        defer parsed.deinit();

        const reply = try replyText(parsed.value);
        if (reply.is_error) return error.ToolReturnedError;

        const seen = client.sessionId() orelse return error.NoSessionId;
        @memcpy(session.session_id[0..seen.len], seen);
        session.session_id_len = seen.len;
        @memcpy(session.doubled[0..reply.text.len], reply.text);
        session.doubled_len = reply.text.len;
    }

    fn sessionId(session: *const Session) []const u8 {
        return session.session_id[0..session.session_id_len];
    }

    fn doubledText(session: *const Session) []const u8 {
        return session.doubled[0..session.doubled_len];
    }
};

test "two clients on two threads run independent sessions" {
    var a: Session = .{};
    var b: Session = .{};

    const t1 = try std.Thread.spawn(.{}, Session.run, .{ &a, "SESSION_A" });
    const t2 = try std.Thread.spawn(.{}, Session.run, .{ &b, "SESSION_B" });
    t1.join();
    t2.join();

    if (a.err) |e| return e;
    if (b.err) |e| return e;

    try std.testing.expectEqualStrings("SESSION_A", a.sessionId());
    try std.testing.expectEqualStrings("SESSION_B", b.sessionId());

    try std.testing.expectEqualStrings("82", a.doubledText());
    try std.testing.expectEqualStrings("82", b.doubledText());
}

// --- thread safety ---

// Echo interleaved sends to expose invalid JSON.
const echo_stub =
    \\#!/bin/sh
    \\trap '' PIPE
    \\while IFS= read -r line; do printf '%s\n' "$line"; done
    \\exit 0
    \\
;

const sender_threads = 8;
const sends_per_thread = 64;
// Exceed the writer buffer to force flushes during concurrent sends.
const send_text_bytes = 3 * 1024;

// Distinct letters expose mixed thread payloads.
const Sender = struct {
    client: *agent.Client,
    letter: u8,
    err: ?anyerror = null,

    fn run(s: *Sender) void {
        var text: [send_text_bytes]u8 = undefined;
        @memset(&text, s.letter);
        var i: usize = 0;
        while (i < sends_per_thread) : (i += 1) {
            s.client.send(&text) catch |e| {
                s.err = e;
                return;
            };
        }
    }
};

const Reader = struct {
    client: *agent.Client,
    user_events: usize = 0,
    err: ?anyerror = null,

    fn run(r: *Reader) void {
        while (true) {
            const maybe = r.client.next() catch |e| {
                r.err = e;
                return;
            };
            var event = maybe orelse return;
            defer event.deinit();
            if (event.kind == .user) r.user_events += 1;
        }
    }
};

test "sends from several threads never interleave on the pipe" {
    var stub = try Stub.init(echo_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    var reader: Reader = .{ .client = client };
    const reader_thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});

    var senders: [sender_threads]Sender = undefined;
    var threads: [sender_threads]std.Thread = undefined;
    for (&senders, 0..) |*s, i| {
        s.* = .{ .client = client, .letter = 'a' + @as(u8, @intCast(i)) };
        threads[i] = try std.Thread.spawn(.{}, Sender.run, .{s});
    }
    for (threads) |t| t.join();

    client.closeStdin();
    reader_thread.join();

    for (senders) |s| if (s.err) |e| return e;
    if (reader.err) |e| return e;
    try std.testing.expectEqual(@as(usize, sender_threads * sends_per_thread), reader.user_events);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try client.wait());
}

fn killAfter(client: *agent.Client, ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
    client.kill();
}

// Exec keeps the signal on the process holding pipes open past stdin EOF.
const lingering_stub =
    \\#!/bin/sh
    \\printf '{"type":"system","subtype":"init","session_id":"L1"}\n'
    \\exec sleep 5
    \\
;

test "kill from another thread releases a wait parked on a child that ignores stdin" {
    var stub = try Stub.init(lingering_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    const watchdog = try std.Thread.spawn(.{}, killAfter, .{ client, 200 });
    const term = try client.wait();
    watchdog.join();

    try std.testing.expect(client.killed);
    try std.testing.expectEqual(std.process.Child.Term{ .signal = std.posix.SIG.TERM }, term);
}

test "kill from another thread ends a next blocked on a child that never exits" {
    var stub = try Stub.init(lingering_stub);
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    const watchdog = try std.Thread.spawn(.{}, killAfter, .{ client, 200 });
    try std.testing.expectEqual(@as(usize, 1), try drain(client));
    watchdog.join();

    try std.testing.expect(client.killed);
    try std.testing.expect(try client.next() == null);
}

const Waiter = struct {
    client: *agent.Client,
    term: ?std.process.Child.Term = null,
    err: ?anyerror = null,

    fn run(w: *Waiter) void {
        w.term = w.client.wait() catch |e| {
            w.err = e;
            return;
        };
    }
};

test "concurrent waits reap once and agree on the status" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\sleep 0.3
        \\exit 4
        \\
    );
    defer stub.deinit();

    const client = try stub.open(.{});
    defer _ = client.close();

    var waiter: Waiter = .{ .client = client };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    const term = try client.wait();
    thread.join();

    if (waiter.err) |e| return e;
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 4 }, term);
    try std.testing.expectEqual(term, waiter.term.?);
}

const ignores_term_stub =
    \\#!/bin/sh
    \\trap '' TERM
    \\printf '{"type":"result","result":"ready"}\n'
    \\exec sleep 4
    \\
;

fn ready(client: *agent.Client) !void {
    var event = (try client.next()).?;
    defer event.deinit();
    try std.testing.expectEqualStrings("ready", event.resultText().?);
}

test "termination escalates an ignored TERM within its grace period" {
    var stub = try Stub.init(ignores_term_stub);
    defer stub.deinit();
    const client = try stub.open(.{ .termination_grace_ms = 30 });
    defer _ = client.close();
    try ready(client);
    const start = std.Io.Clock.awake.now(io);
    const term = try client.terminate(30);
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(elapsed < 1_500);
    try std.testing.expectEqual(agent.Term{ .signal = .KILL }, term);
    const status = client.status();
    try std.testing.expect(status.killed and status.force_killed and status.stdin_closed);
    try std.testing.expectEqual(term, status.term.?);
    try std.testing.expectEqual(term, try client.forceKill());
    try std.testing.expectEqual(term, try client.terminate(0));
}

test "no-read initialization times out and force-cleans a TERM-ignoring child" {
    var stub = try Stub.init(ignores_term_stub);
    defer stub.deinit();
    const large_skill = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(large_skill);
    @memset(large_skill, 's');
    const start = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.WriteTimedOut, stub.open(.{
        .skills = &.{large_skill},
        .write_timeout_ms = 50,
    }));
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 1_500);
}

test "a timed-out write poisons the transport and next observes it immediately" {
    var stub = try Stub.init(ignores_term_stub);
    defer stub.deinit();
    const client = try stub.open(.{ .write_timeout_ms = 40 });
    defer _ = client.close();
    defer _ = client.forceKill() catch {};
    try ready(client);
    const text = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(text);
    @memset(text, 'x');
    try std.testing.expectError(error.WriteTimedOut, client.send(text));
    try std.testing.expect(client.status().transport_failed);
    try std.testing.expectError(error.TransportFailed, client.send("later"));
    try std.testing.expectError(error.TransportFailed, client.interrupt());
    try std.testing.expectError(error.TransportFailed, client.next());
}

const BlockedSender = struct {
    client: *agent.Client,
    text: []const u8,
    started: std.atomic.Value(bool) = .init(false),
    err: ?agent.WriteError = null,

    fn run(sender: *BlockedSender) void {
        sender.started.store(true, .release);
        sender.client.send(sender.text) catch |err| {
            sender.err = err;
        };
    }
};

test "force recovery bypasses a full stdin pipe and simultaneous stdout pressure" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\trap '' TERM
        \\printf '{"type":"result","result":"ready"}\n'
        \\exec yes '{"type":"result","result":"pressure"}'
        \\
    );
    defer stub.deinit();
    const client = try stub.open(.{ .write_timeout_ms = 5_000 });
    defer _ = client.close();
    try ready(client);
    const text = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(text);
    @memset(text, 'x');
    var sender: BlockedSender = .{ .client = client, .text = text };
    const sending = try std.Thread.spawn(.{}, BlockedSender.run, .{&sender});
    var joined_sender = false;
    defer if (!joined_sender) {
        _ = client.forceKill() catch {};
        sending.join();
    };
    while (!sender.started.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
    try io.sleep(.fromMilliseconds(20), .awake);
    var waiter: Waiter = .{ .client = client };
    const waiting = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    var joined_waiter = false;
    defer if (!joined_waiter) {
        _ = client.forceKill() catch {};
        waiting.join();
    };
    const start = std.Io.Clock.awake.now(io);
    const term = try client.terminate(30);
    sending.join();
    joined_sender = true;
    waiting.join();
    joined_waiter = true;
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 1_500);
    try std.testing.expect(sender.err != null);
    if (waiter.err) |err| return err;
    try std.testing.expectEqual(term, waiter.term.?);
    try std.testing.expectEqual(agent.Term{ .signal = .KILL }, term);
}

test "reaping releases a reader while a descendant retains stdout" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\sleep 2 &
        \\printf '{"type":"result","result":"ready"}\n'
        \\exit 0
        \\
    );
    defer stub.deinit();
    const client = try stub.open(.{});
    defer _ = client.close();
    try ready(client);
    const start = std.Io.Clock.awake.now(io);
    try std.testing.expectEqual(agent.Term{ .exited = 0 }, try client.wait());
    try std.testing.expect(try client.next() == null);
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 1_000);
}

test "one-byte pipe buffers preserve fragmented frames and escaped commands" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\IFS= read -r message || exit 1
        \\printf '{"type":'
        \\printf '"result","result":"ok"}\n'
        \\
    );
    defer stub.deinit();
    const client = try stub.open(.{ .stdin_buffer_size = 1, .stdout_buffer_size = 1 });
    defer _ = client.close();
    try client.sendCommand("test", "a \"b\"\n");
    var event = (try client.next()).?;
    defer event.deinit();
    try std.testing.expectEqualStrings("ok", event.resultText().?);
    try std.testing.expect(try client.next() == null);
}

test "deep JSON is a terminal protocol error before reserialization" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\printf '{"type":"control_request","request_id":"deep","request":{"subtype":"can_use_tool","tool_name":"Read","input":'
        \\i=0
        \\while [ "$i" -lt 300 ]; do printf '['; i=$((i+1)); done
        \\printf '0'
        \\i=0
        \\while [ "$i" -lt 300 ]; do printf ']'; i=$((i+1)); done
        \\printf '}}\n'
        \\exec sleep 4
        \\
    );
    defer stub.deinit();
    const client = try stub.open(.{});
    defer _ = client.close();
    try std.testing.expectError(error.ProtocolTooDeep, client.next());
    try std.testing.expect(client.status().term != null);
    try std.testing.expect(try client.next() == null);
}

const StatusReader = struct {
    client: *agent.Client,
    done: std.atomic.Value(bool) = .init(false),
    invalid: bool = false,
    fn run(reader: *StatusReader) void {
        while (!reader.done.load(.acquire)) {
            const snapshot = reader.client.status();
            if (snapshot.force_killed and !snapshot.killed) reader.invalid = true;
            std.Thread.yield() catch {};
        }
    }
};

test "status snapshots remain coherent during concurrent wait and termination" {
    var stub = try Stub.init(ignores_term_stub);
    defer stub.deinit();
    const client = try stub.open(.{});
    defer _ = client.close();
    try ready(client);
    var reader: StatusReader = .{ .client = client };
    const thread = try std.Thread.spawn(.{}, StatusReader.run, .{&reader});
    var joined = false;
    defer if (!joined) {
        reader.done.store(true, .release);
        thread.join();
    };
    _ = try client.terminate(20);
    try std.testing.expect(client.status().term != null);
    reader.done.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(!reader.invalid);
}

test "configuration validation rejects unusable transport and ambiguous registrations before spawn" {
    const missing = "/nonexistent/claude";
    for ([_]agent.Options{
        .{ .claude_path = missing, .stdin_buffer_size = 0 },
        .{ .claude_path = missing, .stdout_buffer_size = 0 },
    }) |options| try std.testing.expectError(error.InvalidBufferSize, agent.Client.open(gpa, io, options));
    try std.testing.expectError(error.InvalidWriteTimeout, agent.Client.open(gpa, io, .{
        .claude_path = missing,
        .write_timeout_ms = 0,
    }));
    for ([_][]const agent.McpServer{
        &.{.{ .name = "" }},
        &.{ .{ .name = "s" }, .{ .name = "s" } },
        &.{.{ .name = "s", .tools = &.{
            .{ .name = "t", .description = "d", .handler = recordingHandler },
            .{ .name = "t", .description = "d", .handler = recordingHandler },
        } }},
        &.{.{ .name = "s", .tools = &.{.{ .name = "", .description = "d", .handler = recordingHandler }} }},
    }) |servers| try std.testing.expectError(error.InvalidRegistration, agent.Client.open(gpa, io, .{
        .claude_path = missing,
        .sdk_mcp_servers = servers,
    }));
}

fn cancelableOpen(options: agent.Options) agent.OpenError!void {
    const client = try agent.Client.open(gpa, io, options);
    defer _ = client.close();
    _ = client.forceKill() catch {};
}

test "canceling initialization force-cleans the spawned child before returning" {
    var stub = try Stub.init(
        \\#!/bin/sh
        \\trap '' TERM
        \\touch ready.flag
        \\exec sleep 4
        \\
    );
    defer stub.deinit();
    const text = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(text);
    @memset(text, 's');
    var future = try io.concurrent(cancelableOpen, .{agent.Options{
        .claude_path = stub.path,
        .cwd = .{ .dir = stub.tmp.dir },
        .skills = &.{text},
        .write_timeout_ms = 5_000,
    }});
    defer future.cancel(io) catch {};
    const ready_deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(1_500));
    while (true) {
        if (stub.tmp.dir.access(io, "ready.flag", .{})) |_| break else |err| {
            if (err != error.FileNotFound) return err;
        }
        if (std.Io.Clock.awake.now(io).nanoseconds >= ready_deadline.nanoseconds) return error.ChildNotReady;
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    const start = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.WriteFailed, future.cancel(io));
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 1_500);
}

test "MCP calls after a foreground result remain serviceable until explicit stdin closure" {
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
    var stub = try Stub.init(
        "#!/bin/sh\n" ++
            "IFS= read -r initialization || exit 1\n" ++
            "printf '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"zig_1\",\"response\":{}}}\\n'\n" ++
            "IFS= read -r turn || exit 2\n" ++
            "printf '{\"type\":\"result\",\"result\":\"foreground-complete\"}\\n'\n" ++
            tool_call_line ++ "\n" ++
            "IFS= read -r reply || exit 3\n" ++
            "printf '{\"type\":\"result\",\"result\":\"background-complete\",\"reply\":%s}\\n' \"$reply\"\n" ++
            "if IFS= read -r extra; then exit 4; fi\n" ++
            "exit 0\n",
    );
    defer stub.deinit();
    const client = try stub.open(.{ .sdk_mcp_servers = &servers });
    defer _ = client.close();
    errdefer _ = client.forceKill() catch {};
    try client.send("foreground work");

    var foreground = (try client.next()).?;
    defer foreground.deinit();
    try std.testing.expectEqual(agent.Kind.result, foreground.kind);
    try std.testing.expectEqualStrings("foreground-complete", foreground.resultText().?);
    try std.testing.expectEqual(agent.InitializationState.accepted, client.status().initialization);
    try std.testing.expect(!client.status().stdin_closed);
    try std.testing.expect(!record.ran);

    var background = (try client.next()).?;
    defer background.deinit();
    try std.testing.expectEqual(agent.Kind.result, background.kind);
    try std.testing.expectEqualStrings("background-complete", background.resultText().?);
    try std.testing.expect(record.ran);
    try std.testing.expectEqual(@as(i64, 41), record.n);
    try std.testing.expect(!client.status().stdin_closed);
    const response = background.parsed.value.object.get("reply").?.object.get("response").?.object;
    try std.testing.expectEqualStrings("c1", response.get("request_id").?.string);
    try std.testing.expectEqualStrings("success", response.get("subtype").?.string);
    const message = response.get("response").?.object.get("mcp_response").?.object;
    try std.testing.expectEqual(@as(i64, 9), message.get("id").?.integer);
    const result = message.get("result").?.object;
    try std.testing.expect(!result.get("isError").?.bool);
    try std.testing.expectEqualStrings("ok", result.get("content").?.array.items[0].object.get("text").?.string);

    client.closeStdin();
    try std.testing.expect(try client.next() == null);
    try std.testing.expectEqual(agent.Term{ .exited = 0 }, try client.wait());
}
