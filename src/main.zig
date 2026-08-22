// src/main.zig
// Streams one turn from the agent, exposing an in-process tool the agent can call.

const std = @import("std");
const agent = @import("agent.zig");

/// Reads from the host process's environment, reached through the context
/// pointer rather than a global.
fn hostEnv(context: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    const environ: *const std.process.Environ.Map = @ptrCast(@alignCast(context.?));
    const obj = switch (arguments) {
        .object => |o| o,
        else => return .{ .text = "expected an object", .is_error = true },
    };
    const name = switch (obj.get("name") orelse return .{ .text = "missing name", .is_error = true }) {
        .string => |v| v,
        else => return .{ .text = "name must be a string", .is_error = true },
    };
    const value = environ.get(name) orelse return .{ .text = "not set", .is_error = true };
    return .{ .text = try arena.dupe(u8, value) };
}

fn addNumbers(_: ?*anyopaque, arena: std.mem.Allocator, arguments: std.json.Value) !agent.ToolResult {
    const obj = switch (arguments) {
        .object => |o| o,
        else => return .{ .text = "expected an object", .is_error = true },
    };
    const a = numberOf(obj.get("a")) orelse return .{ .text = "missing a", .is_error = true };
    const b = numberOf(obj.get("b")) orelse return .{ .text = "missing b", .is_error = true };
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{a + b}) };
}

fn numberOf(value: ?std.json.Value) ?f64 {
    return switch (value orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn buildTools(environ: *const std.process.Environ.Map) [2]agent.Tool {
    return .{
        .{
            .name = "host_env",
            .description = "Read an environment variable from the host process.",
            .input_schema =
            \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
            ,
            .handler = hostEnv,
            .context = @constCast(@ptrCast(environ)),
        },
        .{
            .name = "add",
            .description = "Add two numbers.",
            .input_schema =
            \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
            ,
            .handler = addNumbers,
        },
    };
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

    const tools = buildTools(init.environ_map);
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
