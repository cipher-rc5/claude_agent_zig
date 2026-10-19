const std = @import("std");
const agent = @import("agent");

pub fn main(init: std.process.Init) !void {
    const path = init.environ_map.get("LIVE_CLI") orelse return error.MissingCli;
    const budget = init.environ_map.get("LIVE_BUDGET_USD") orelse return error.MissingBudget;
    const client = try agent.Client.open(init.gpa, init.io, .{
        .claude_path = path,
        .bare = true,
        .tools = "",
        .setting_sources = "",
        .disable_slash_commands = true,
        .strict_mcp_config = true,
        .mcp_config = "{\"mcpServers\":{}}",
        .skills = &.{},
        .max_turns = 1,
        .extra_args = &.{ "--max-budget-usd", budget },
    });
    defer _ = client.close();
    try client.send("Reply with exactly the text compatibility-ok. Do not use tools.");
    var initialized = false;
    var completed = false;
    while (try client.next()) |event| {
        var e = event;
        defer e.deinit();
        if (e.kind == .system and std.mem.eql(u8, e.subtype() orelse "", "init")) initialized = true;
        if (e.kind == .result) {
            if (!std.mem.eql(u8, e.subtype() orelse "", "success")) return error.UnsuccessfulResult;
            const text = e.resultText() orelse return error.MissingResult;
            if (std.mem.indexOf(u8, text, "compatibility-ok") == null) return error.UnexpectedResult;
            completed = true;
            client.closeStdin();
        }
    }
    if (!initialized or !completed or client.status().initialization != .accepted) return error.IncompleteSession;
    const term = try client.wait();
    if (term != .exited or term.exited != 0) return error.UnexpectedExit;
}
