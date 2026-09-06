// examples/demo.zig
// Streams one turn from the agent, exposing an in-process tool the agent can
// call. The tools themselves live in demo_tools.zig.
//
// The library is reached through the `agent` module declared in build.zig,
// not by a relative path: a file may belong to only one module, and a root
// under examples/ cannot import upward out of its own module path.

const std = @import("std");
const agent = @import("agent");
const demo_tools = @import("demo_tools.zig");

test {
    // `main` is only reachable at runtime, so without this the test runner
    // never pulls in the demo tools and their tests silently do not run.
    _ = demo_tools;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const prompt = args.next() orelse "What is 17 plus 25? Use the add tool.";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;

    // Skipped lines are reported here rather than on stdout so that piping
    // stdout still yields only the agent's output.
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const log = &stderr.interface;

    const tools = demo_tools.build(init.environ_map);
    const servers = [_]agent.McpServer{.{ .name = "host", .tools = &tools }};

    // AGENT_SKILLS, when set, is a comma list restricting which skills the
    // agent may invoke. Unset leaves every discovered skill available.
    var skill_names: std.ArrayList([]const u8) = .empty;
    defer skill_names.deinit(gpa);
    if (init.environ_map.get("AGENT_SKILLS")) |list| {
        // An empty AGENT_SKILLS is a deliberate empty allowlist, not "unset".
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |name| {
            const trimmed = std.mem.trim(u8, name, " ");
            if (trimmed.len > 0) try skill_names.append(gpa, trimmed);
        }
    }

    // AGENT_PERMISSIONS=host routes the CLI's permission prompts to this
    // process, where `demo_tools.logAndAllow` logs each one on stderr and
    // allows it. Only calls outside `allowed_tools` prompt, so with the
    // allowlist above this is reached by a Bash or Edit call, say. Unset
    // leaves the CLI's own handling, which refuses what nothing authorized.
    const host_permissions = if (init.environ_map.get("AGENT_PERMISSIONS")) |v|
        std.mem.eql(u8, v, "host")
    else
        false;

    const client = try agent.Client.open(gpa, io, .{
        .claude_path = init.environ_map.get("CLAUDE_BIN") orelse "claude",
        .sdk_mcp_servers = &servers,
        .setting_sources = "user,project",
        .allowed_tools = "mcp__host__*,Skill,Read,Glob,Grep",
        .skills = if (init.environ_map.get("AGENT_SKILLS") != null)
            skill_names.items
        else
            null,
        .permission_handler = if (host_permissions) demo_tools.logAndAllow else null,
        .permission_context = @ptrCast(log),
    });
    // `close` reaps the child; the status it returns is the only signal when
    // the CLI dies on startup, since that produces no events at all and the
    // read loop below just ends. Checked after the loop rather than discarded.
    defer _ = client.close();

    // A prompt beginning with /name dispatches that skill or command; there
    // is nothing special to do for it beyond sending the text.
    try client.send(prompt);
    // stdin stays open for the turn: it is the return path for tool calls.

    while (true) {
        // Two of the four `ReadError`s cost one line and no more, so aborting
        // on them throws away a stream the library went out of its way to keep:
        // on an overlong line `readLine` discards through the next newline to
        // resync to a clean line boundary (src/client.zig), and a line that is
        // not JSON never reaches the reader's state at all. Either way the
        // following line parses normally, so the loop reports the gap and reads
        // on. The rest are not per-line faults — the pipe is gone or the
        // allocator is empty — and there is no next line to advance to.
        const event = client.next() catch |err| switch (err) {
            error.ProtocolTooLong, error.InvalidJson => {
                try log.print("[skipped] unreadable line: {t}\n", .{err});
                try log.flush();
                continue;
            },
            else => |fatal| return fatal,
        } orelse break;

        var e = event;
        defer e.deinit();

        switch (e.kind) {
            .system => {
                if (e.subtype()) |s| {
                    try out.print("[system/{s}]\n", .{s});
                    if (e.getArray("skills")) |skills| {
                        try out.print("[skills] {d} discovered\n", .{skills.len});
                    }
                    try out.flush();
                }
            },
            .stream_event => {
                if (e.textDelta()) |text| {
                    try out.writeAll(text);
                    try out.flush();
                }
            },
            .result => {
                try out.print("\n[result] session={s}\n", .{e.sessionId() orelse "?"});
                if (e.resultText()) |text| try out.print("{s}\n", .{text});
                try out.flush();
                // One turn only, so signal end of input now.
                client.closeStdin();
            },
            else => {},
        }
    }

    // A CLI that failed to start streams nothing, so the loop above ends
    // normally and the exit status is what distinguishes that from success.
    // Returning an error here would collapse every failure into one name and
    // drop the status itself, which is the only detail a shell caller can act
    // on. Exiting with the child's own code forwards it instead. `process.exit`
    // does not unwind, so stdout is flushed first and the `defer`s above are
    // deliberately given up: the child is already reaped by `wait`, and the
    // remaining allocations die with the process.
    switch (try client.wait()) {
        .exited => |code| if (code != 0) {
            try out.print("[exit] the CLI exited with status {d}\n", .{code});
            try out.flush();
            std.process.exit(code);
        },
        // Signalled or stopped: there is no exit code to forward, and 1 is the
        // conventional stand-in.
        else => |term| {
            try out.print("[exit] the CLI ended abnormally: {any}\n", .{term});
            try out.flush();
            std.process.exit(1);
        },
    }
}
