// examples/demo.zig
// Streams one foreground turn with the tools in demo_tools.zig.

const std = @import("std");
const agent = @import("agent");
const demo_tools = @import("demo_tools.zig");

test {
    // Reference demo tools explicitly so their tests run.
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

    // Keep diagnostics on stderr so stdout contains only agent output.
    var stderr_buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const log = &stderr.interface;

    const tools = demo_tools.build(init.environ_map);
    const servers = [_]agent.McpServer{.{ .name = "host", .tools = &tools }};

    // AGENT_SKILLS is a comma-separated invocation allowlist; unset allows all.
    var skill_names: std.ArrayList([]const u8) = .empty;
    defer skill_names.deinit(gpa);
    if (init.environ_map.get("AGENT_SKILLS")) |list| {
        // An empty value explicitly allows no skills.
        var it = std.mem.splitScalar(u8, list, ',');
        while (it.next()) |name| {
            const trimmed = std.mem.trim(u8, name, " ");
            if (trimmed.len > 0) try skill_names.append(gpa, trimmed);
        }
    }

    // AGENT_PERMISSIONS=host logs and allows prompts for calls outside the
    // allowlist. Unset uses the CLI default, which refuses unauthorized calls.
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
    // Inspect the exit status after streaming to catch startup failures.
    defer {
        _ = client.terminate(250) catch {};
        _ = client.close();
    }

    // The CLI dispatches prompts beginning with /name as skills or commands.
    try client.send(prompt);
    // Keep stdin open for tool replies until the turn ends.

    while (true) {
        // Invalid JSON and oversized lines discard one line; report and
        // continue. Other read errors end the session.
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
                // The single turn is complete; signal EOF.
                client.closeStdin();
            },
            else => {},
        }
    }

    // Forward the child exit status, including startup failures with no events.
    // Flush stdout before `process.exit`, which skips deferred cleanup. The
    // child is already reaped; remaining allocations end with this process.
    switch (try client.wait()) {
        .exited => |code| if (code != 0) {
            try out.print("[exit] the CLI exited with status {d}\n", .{code});
            try out.flush();
            std.process.exit(code);
        },
        // Use 1 when the child has no exit code to forward.
        else => |term| {
            try out.print("[exit] the CLI ended abnormally: {any}\n", .{term});
            try out.flush();
            std.process.exit(1);
        },
    }
}
