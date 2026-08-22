// src/main.zig
// Streams one turn from the agent, exposing an in-process tool the agent can
// call. The tools themselves live in demo_tools.zig.

const std = @import("std");
const agent = @import("agent.zig");
const demo_tools = @import("demo_tools.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const prompt = args.next() orelse "What is 17 plus 25? Use the add tool.";

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout.interface;

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

    const client = try agent.Client.open(gpa, io, .{
        .claude_path = init.environ_map.get("CLAUDE_BIN") orelse "claude",
        .sdk_mcp_servers = &servers,
        .setting_sources = "user,project",
        .allowed_tools = "mcp__host__*,Skill,Read,Glob,Grep",
        .skills = if (init.environ_map.get("AGENT_SKILLS") != null)
            skill_names.items
        else
            null,
    });
    defer _ = client.close();

    // A prompt beginning with /name dispatches that skill or command; there
    // is nothing special to do for it beyond sending the text.
    try client.send(prompt);
    // stdin stays open for the turn: it is the return path for tool calls.

    while (try client.next()) |event| {
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
}
