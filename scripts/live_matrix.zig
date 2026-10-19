const std = @import("std");
const agent = @import("agent");

const TerminalSubtype = enum { success, error_during_execution, error_max_turns, error_max_budget_usd, error_max_structured_output_retries, other };
const TerminalReason = enum { completed, aborted_streaming, aborted_tools, api_error, max_turns, max_budget, max_budget_usd, missing, other };

const Context = struct {
    io: std.Io,
    log: *std.Io.Writer,
    report_log: *std.Io.Writer,
    scenario: []const u8,
    nonce: []const u8,
    phase: []const u8 = "main",
    tool_calls: usize = 0,
    permission_calls: usize = 0,

    fn record(context: *Context, value: anytype) !void {
        try std.json.Stringify.value(value, .{}, context.report_log);
        try context.report_log.writeByte('\n');
        try context.report_log.flush();
        try std.json.Stringify.value(value, .{}, context.log);
        try context.log.writeByte('\n');
        try context.log.flush();
    }

    fn is(context: *const Context, scenario: []const u8) bool {
        return std.mem.eql(u8, context.scenario, scenario);
    }
};

fn field(object: std.json.Value, key: []const u8) ?[]const u8 {
    if (object != .object) return null;
    const value = object.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn probe(raw: ?*anyopaque, _: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const value = field(arguments, "value") orelse return error.MissingValue;
    const nonce = field(arguments, "nonce") orelse return error.MissingNonce;
    const expected_value = if (context.is("resume")) context.nonce else if (context.is("permission_replace")) "replacement" else "original";
    const expected_nonce = if (context.is("resume")) "resume-proof" else context.nonce;
    const matches = std.mem.eql(u8, value, expected_value) and std.mem.eql(u8, nonce, expected_nonce);
    context.tool_calls += 1;
    try context.record(.{ .event = "tool_called", .phase = context.phase, .arguments_match = matches });
    if (!matches) return error.UnexpectedArguments;
    return .{ .text = "matrix-tool-result" };
}

fn permission(raw: ?*anyopaque, arena: std.mem.Allocator, name: []const u8, input: std.json.Value) !agent.PermissionDecision {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.permission_calls += 1;
    const expected_tool = std.mem.eql(u8, name, "mcp__matrix__probe");
    const input_matches = expected_tool and
        std.mem.eql(u8, field(input, "value") orelse "", "original") and
        std.mem.eql(u8, field(input, "nonce") orelse "", context.nonce);
    try context.record(.{
        .event = "permission_called",
        .phase = context.phase,
        .tool_matches = expected_tool,
        .input_matches = input_matches,
        .decision = if (context.is("permission_deny")) "deny" else if (context.is("permission_replace")) "replace" else "allow",
    });
    if (!input_matches) return .{ .deny = "matrix unexpected permission input" };
    if (context.is("permission_deny")) return .{ .deny = "matrix deliberate denial; do not retry" };
    if (context.is("permission_replace")) return .{ .allow_with_input = try std.fmt.allocPrint(arena, "{{\"value\":\"replacement\",\"nonce\":\"{s}\"}}", .{context.nonce}) };
    return .allow;
}

fn session(
    init: std.process.Init,
    context: *Context,
    resume_id: ?[]const u8,
) !?[]u8 {
    const gpa = init.gpa;
    const is_interrupt = context.is("interrupt") or context.is("interrupt_rejection");
    const tools = [_]agent.Tool{.{
        .name = "probe",
        .description = "Harmless compatibility probe: records value and nonce; no host side effects.",
        .input_schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"},\"nonce\":{\"type\":\"string\"}},\"required\":[\"value\",\"nonce\"],\"additionalProperties\":false}",
        .handler = probe,
        .context = context,
    }};
    const servers = [_]agent.McpServer{.{ .name = "matrix", .tools = &tools }};
    const budget = init.environ_map.get("LIVE_BUDGET_USD") orelse return error.MissingBudget;
    var extras: std.ArrayList([]const u8) = .empty;
    defer extras.deinit(gpa);
    try extras.appendSlice(gpa, &.{
        "--max-budget-usd", budget,
        "--system-prompt",  "You are a compatibility test participant. Follow the user's precise harmless protocol instructions. Use no other tools. Never retry a denied or failed tool call.",
        "--settings",       "{\"disableAllHooks\":true}",
        "--no-chrome",
    });
    if (!context.is("resume")) try extras.append(gpa, "--no-session-persistence");
    if (resume_id == null) try extras.appendSlice(gpa, &.{ "--session-id", init.environ_map.get("LIVE_SEED_SESSION_ID") orelse return error.MissingSeedSessionId });
    const needs_permission = context.is("permission_allow") or context.is("permission_deny") or context.is("permission_replace");
    const client = try agent.Client.open(gpa, init.io, .{
        .claude_path = init.environ_map.get("LIVE_CLI") orelse return error.MissingCli,
        .model = init.environ_map.get("LIVE_MODEL") orelse "haiku",
        .tools = "",
        .setting_sources = "",
        .disable_slash_commands = true,
        .strict_mcp_config = true,
        .mcp_config = "{\"mcpServers\":{}}",
        .skills = &.{},
        .sdk_mcp_servers = if (is_interrupt) &.{} else &servers,
        .permission_mode = .manual,
        .allowed_tools = if (needs_permission) null else "mcp__matrix__probe",
        .permission_handler = if (needs_permission) permission else null,
        .permission_context = context,
        .resume_session_id = resume_id,
        .max_turns = if (is_interrupt or (context.is("resume") and resume_id == null)) 1 else 2,
        .extra_args = extras.items,
    });
    defer _ = client.close();
    var interrupt_prefix: std.ArrayList(u8) = .empty;
    defer interrupt_prefix.deinit(gpa);
    var interrupted = false;
    var rejected = false;
    var initialized = false;
    var completed = false;
    var terminal_subtype: TerminalSubtype = .other;
    var terminal_reason: TerminalReason = .missing;
    var terminal_is_error: ?bool = null;
    var session_id: ?[]u8 = null;
    errdefer if (session_id) |id| gpa.free(id);
    if (context.is("interrupt_rejection")) {
        // The bridge mutates only the second request; the real CLI must reject it.
        try client.interrupt();
        try client.interrupt();
    } else {
        const prompt = if (context.is("interrupt"))
            try gpa.dupe(u8, "This is a short formatting fixture. Output the integers 1 through 300 in order, one per line, then the exact marker MATRIX-END. Plain text only; no headers, prose, code fences, or tools. Complete all 300 numbers.")
        else if (context.is("resume") and resume_id == null)
            try std.fmt.allocPrint(gpa, "Remember this secret marker for the next user turn: {s}. Do not call any tool now. Reply only acknowledged.", .{context.nonce})
        else if (context.is("resume"))
            try gpa.dupe(u8, "Call mcp__matrix__probe exactly once. Set value to the secret marker from the previous user turn and nonce to resume-proof. This message intentionally does not repeat the marker. Then stop.")
        else
            try std.fmt.allocPrint(gpa, "Call mcp__matrix__probe exactly once with value=original and nonce={s}. After this one tool call or a denial, stop and reply done. Do not retry or call another tool.", .{context.nonce});
        defer gpa.free(prompt);
        try client.send(prompt);
    }
    while (true) {
        const event = client.next() catch |err| {
            if (err == error.ControlRequestRejected and context.is("interrupt_rejection")) {
                rejected = true;
                try context.record(.{ .event = "interrupt_rejection_observed", .phase = context.phase, .has_error = client.lastControlError() != null });
                client.closeStdin();
                continue;
            }
            return err;
        } orelse break;
        var e = event;
        defer e.deinit();
        if (e.kind == .system and std.mem.eql(u8, e.subtype() orelse "", "init")) {
            initialized = true;
            try context.record(.{ .event = "system_init", .phase = context.phase, .initialization = @tagName(client.status().initialization) });
        }
        if (context.is("interrupt") and !interrupted) {
            if (e.textDelta()) |text| {
                const remaining = 256 - interrupt_prefix.items.len;
                try interrupt_prefix.appendSlice(gpa, text[0..@min(remaining, text.len)]);
                if (std.mem.indexOf(u8, interrupt_prefix.items, "1\n2\n3\n4\n5") != null) {
                    try client.interrupt();
                    interrupted = true;
                    try context.record(.{ .event = "interrupt_sent_midturn", .phase = context.phase, .prefix_sequence_observed = true });
                }
            }
        }
        if (e.kind == .result) {
            completed = true;
            terminal_subtype = std.meta.stringToEnum(TerminalSubtype, e.subtype() orelse "") orelse .other;
            terminal_reason = if (e.getString("terminal_reason")) |reason| std.meta.stringToEnum(TerminalReason, reason) orelse .other else .missing;
            if (e.root() == .object) {
                if (e.root().object.get("is_error")) |value| {
                    terminal_is_error = if (value == .bool) value.bool else null;
                }
            }
            const success = terminal_subtype == .success and terminal_is_error == false;
            const canceled = context.is("interrupt") and interrupted and terminal_subtype == .error_during_execution and
                terminal_is_error == true and terminal_reason == .aborted_streaming;
            try context.record(.{ .event = "result_received", .phase = context.phase, .success = success, .canceled = canceled, .subtype = @tagName(terminal_subtype), .is_error = terminal_is_error, .terminal_reason = @tagName(terminal_reason) });
            if (!success and !canceled) return error.UnsuccessfulResult;
            if (client.sessionId()) |id| session_id = try gpa.dupe(u8, id);
            client.closeStdin();
        }
    }
    const status = client.status();
    try context.record(.{
        .event = "session_complete",
        .phase = context.phase,
        .initialization = @tagName(status.initialization),
        .initialized = initialized,
        .completed = completed,
        .interrupted = interrupted,
        .rejected = rejected,
        .tool_calls = context.tool_calls,
        .permission_calls = context.permission_calls,
        .resume_id_matches = if (resume_id) |id| if (session_id) |seen| std.mem.eql(u8, id, seen) else false else true,
    });
    if (status.initialization != .accepted) return error.InitializationNotAccepted;
    if (context.is("interrupt_rejection")) {
        if (!rejected) return error.ExpectedRejection;
    } else {
        if (!initialized or !completed) return error.IncompleteSession;
        if (context.is("interrupt") and !interrupted) return error.InterruptWasNotSent;
    }
    const term = try client.wait();
    const exit_code: ?u8 = if (term == .exited) term.exited else null;
    try context.record(.{ .event = "cli_exit_observed", .phase = context.phase, .exit_code = exit_code, .terminal_subtype = @tagName(terminal_subtype), .terminal_is_error = terminal_is_error, .terminal_reason = @tagName(terminal_reason) });
    const expected_exit: u8 = if (context.is("interrupt") and interrupted and terminal_subtype == .error_during_execution and
        terminal_is_error == true and terminal_reason == .aborted_streaming) 1 else 0;
    if (exit_code != expected_exit) return error.UnexpectedCliExit;
    return session_id;
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const report_file = try std.Io.Dir.cwd().createFile(init.io, init.environ_map.get("LIVE_SDK_TRACE") orelse return error.MissingReportPath, .{
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    defer report_file.close(init.io);
    var report_buffer: [4096]u8 = undefined;
    var report = report_file.writerStreaming(init.io, &report_buffer);
    var context: Context = .{
        .io = init.io,
        .log = &stdout.interface,
        .report_log = &report.interface,
        .scenario = init.environ_map.get("LIVE_SCENARIO") orelse return error.MissingScenario,
        .nonce = init.environ_map.get("LIVE_NONCE") orelse return error.MissingNonce,
    };
    if (context.is("resume")) {
        context.phase = "seed";
        const first = (try session(init, &context, null)) orelse return error.MissingSessionId;
        defer init.gpa.free(first);
        if (context.tool_calls != 0) return error.UnexpectedSeedToolCall;
        context.phase = "resume";
        const second = (try session(init, &context, first)) orelse return error.MissingResumedId;
        defer init.gpa.free(second);
        if (!std.mem.eql(u8, first, second) or context.tool_calls != 1) return error.ResumeNotProven;
    } else {
        const id = try session(init, &context, null);
        if (id) |value| init.gpa.free(value);
        const expected_calls: usize = if (context.is("permission_deny") or context.is("interrupt") or context.is("interrupt_rejection")) 0 else 1;
        if (context.tool_calls != expected_calls) return error.UnexpectedToolCallCount;
        const expected_permissions: usize = if (context.is("permission_allow") or context.is("permission_deny") or context.is("permission_replace")) 1 else 0;
        if (context.permission_calls != expected_permissions) return error.UnexpectedPermissionCount;
    }
    try context.record(.{ .event = "scenario_complete", .scenario = context.scenario });
}
