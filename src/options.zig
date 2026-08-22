// src/options.zig
// Session configuration, and the CLI flags it translates into.

const std = @import("std");
const Allocator = std.mem.Allocator;

const McpServer = @import("tool.zig").McpServer;

pub const PermissionMode = enum {
    manual,
    auto,
    dont_ask,
    accept_edits,
    /// Skips every permission check, for every tool, with no prompt and no
    /// allowlist consulted. That includes writes and shell commands, so the
    /// agent can do anything the host process can. Use it only where the blast
    /// radius is already contained, such as a disposable container or VM.
    bypass_permissions,
    plan,

    pub fn cliName(mode: PermissionMode) []const u8 {
        return switch (mode) {
            .manual => "manual",
            .auto => "auto",
            .dont_ask => "dontAsk",
            .accept_edits => "acceptEdits",
            .bypass_permissions => "bypassPermissions",
            .plan => "plan",
        };
    }
};

pub const Options = struct {
    /// Path to the CLI, or a bare name resolved through PATH.
    claude_path: []const u8 = "claude",
    /// Working directory for the agent.
    cwd: std.process.Child.Cwd = .inherit,
    /// Skip auto-discovery of hooks, plugins, MCP servers, auto memory and
    /// CLAUDE.md. Also narrows the built-in tool set to the shell and file
    /// tools, so WebSearch, WebFetch, Agent, Skill and the rest are not
    /// registered. Off by default; turn it on only for locked-down CI runs
    /// that want a fixed tool set, and note it requires ANTHROPIC_API_KEY
    /// rather than subscription auth.
    bare: bool = false,
    /// Emit `stream_event` deltas as tokens are produced.
    include_partial_messages: bool = true,
    model: ?[]const u8 = null,
    /// Permission rule syntax, for example `Read,Edit,Bash(git diff *)`.
    allowed_tools: ?[]const u8 = null,
    permission_mode: ?PermissionMode = null,
    append_system_prompt: ?[]const u8 = null,
    /// Path to an MCP config file, or an inline JSON object.
    mcp_config: ?[]const u8 = null,
    /// Restricts the session's built-in tools to the ones named here, for
    /// example `Read,Edit,Bash,WebSearch`. Leave null to keep the full set.
    /// Skills run through the `Skill` tool, so include it when passing a list.
    tools: ?[]const u8 = null,
    /// Which filesystem settings load, as a comma list of `user`, `project`,
    /// and `local`. This is what governs skill discovery: `user` picks up
    /// `~/.claude/skills/`, `project` picks up `.claude/skills/` in the
    /// working directory and its parents up to the repository root. Leave
    /// null for the CLI default.
    setting_sources: ?[]const u8 = null,
    /// Extra working directories. Each contributes its `.claude/skills/`, but
    /// not its commands or agents.
    add_dirs: []const []const u8 = &.{},
    /// Plugin directories to load for this session. A plugin can carry skills,
    /// subagents, hooks, and MCP servers.
    plugin_dirs: []const []const u8 = &.{},
    /// Subagent definitions as a JSON object.
    agents_json: ?[]const u8 = null,
    /// Turns off every skill and command for the session.
    disable_slash_commands: bool = false,
    /// Ignore every MCP source except `mcp_config`.
    strict_mcp_config: bool = false,
    max_turns: ?u32 = null,
    /// Restricts which discovered skills Claude may invoke, by name. This is
    /// an invocation allowlist, not a discovery filter: `system/init` still
    /// reports every skill it found either way, but a skill outside the list
    /// cannot be called. Note that null and an empty slice differ. Leave it
    /// null to allow every discovered skill; pass an empty slice to allow
    /// none. Sent on the `initialize` control request rather than as a CLI
    /// flag, so it needs no `extra_args`.
    skills: ?[]const []const u8 = null,
    /// In-process MCP servers. Tools live in this process and are reached
    /// over the control protocol, so no subprocess is involved.
    sdk_mcp_servers: []const McpServer = &.{},
    /// Resume an existing session by id.
    resume_session_id: ?[]const u8 = null,
    /// Appended verbatim after the flags this module generates.
    extra_args: []const []const u8 = &.{},

    stdout_buffer_size: usize = 64 * 1024,
    stdin_buffer_size: usize = 16 * 1024,
    /// Refuse to buffer a single protocol line larger than this.
    max_line_bytes: usize = 32 * 1024 * 1024,

    /// Whether the session needs an `initialize` control request before the
    /// first turn. Skills being set at all counts, since an empty allowlist
    /// still has to be declared.
    pub fn needsInitialize(options: Options) bool {
        return options.sdk_mcp_servers.len > 0 or options.skills != null;
    }
};

pub fn buildArgv(arena: Allocator, options: Options) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;

    try argv.append(arena, options.claude_path);
    try argv.appendSlice(arena, &.{
        "--print",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
    });
    if (options.bare) try argv.append(arena, "--bare");
    if (options.include_partial_messages) try argv.append(arena, "--include-partial-messages");
    if (options.model) |v| try argv.appendSlice(arena, &.{ "--model", v });
    if (options.allowed_tools) |v| try argv.appendSlice(arena, &.{ "--allowedTools", v });
    if (options.permission_mode) |v| {
        try argv.appendSlice(arena, &.{ "--permission-mode", v.cliName() });
    }
    if (options.append_system_prompt) |v| {
        try argv.appendSlice(arena, &.{ "--append-system-prompt", v });
    }
    if (options.tools) |v| try argv.appendSlice(arena, &.{ "--tools", v });
    if (options.setting_sources) |v| try argv.appendSlice(arena, &.{ "--setting-sources", v });
    for (options.add_dirs) |v| try argv.appendSlice(arena, &.{ "--add-dir", v });
    for (options.plugin_dirs) |v| try argv.appendSlice(arena, &.{ "--plugin-dir", v });
    if (options.agents_json) |v| try argv.appendSlice(arena, &.{ "--agents", v });
    if (options.disable_slash_commands) try argv.append(arena, "--disable-slash-commands");
    if (options.strict_mcp_config) try argv.append(arena, "--strict-mcp-config");
    if (options.max_turns) |v| {
        try argv.appendSlice(arena, &.{ "--max-turns", try std.fmt.allocPrint(arena, "{d}", .{v}) });
    }
    if (options.mcp_config) |v| try argv.appendSlice(arena, &.{ "--mcp-config", v });
    if (options.resume_session_id) |v| try argv.appendSlice(arena, &.{ "--resume", v });
    try argv.appendSlice(arena, options.extra_args);

    return argv.toOwnedSlice(arena);
}

// --- tests ---

// These stay here: they exercise `buildArgv`, which is `pub` so client.zig
// can call it but is not re-exported by agent.zig, so it is not public API.
// Moving them would mean widening the public surface purely for test layout.
// `containsPair` is a test helper, so tests/options_test.zig keeps its own
// copy rather than this one being made public.

fn containsPair(argv: []const []const u8, flag: []const u8, value: []const u8) bool {
    for (argv, 0..) |arg, i| {
        if (!std.mem.eql(u8, arg, flag)) continue;
        if (i + 1 < argv.len and std.mem.eql(u8, argv[i + 1], value)) return true;
    }
    return false;
}

test "argv carries the streaming protocol flags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv(arena.allocator(), .{
        .allowed_tools = "Read,Edit",
        .permission_mode = .accept_edits,
    });

    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expect(containsPair(argv, "--input-format", "stream-json"));
    try std.testing.expect(containsPair(argv, "--output-format", "stream-json"));
    try std.testing.expect(containsPair(argv, "--allowedTools", "Read,Edit"));
    try std.testing.expect(containsPair(argv, "--permission-mode", "acceptEdits"));
}

test "argv carries skill discovery flags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv(arena.allocator(), .{
        .setting_sources = "user,project",
        .add_dirs = &.{ "../shared", "../design" },
        .plugin_dirs = &.{"/opt/plugins/review"},
        .tools = "Skill,Read,Bash",
        .max_turns = 12,
    });

    try std.testing.expect(containsPair(argv, "--setting-sources", "user,project"));
    try std.testing.expect(containsPair(argv, "--add-dir", "../shared"));
    try std.testing.expect(containsPair(argv, "--add-dir", "../design"));
    try std.testing.expect(containsPair(argv, "--plugin-dir", "/opt/plugins/review"));
    try std.testing.expect(containsPair(argv, "--tools", "Skill,Read,Bash"));
    try std.testing.expect(containsPair(argv, "--max-turns", "12"));
    // --bare would defeat all of the above.
    for (argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--bare"));
}
