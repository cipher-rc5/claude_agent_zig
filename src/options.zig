// src/options.zig
// Session options and CLI arguments.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tool_mod = @import("tool.zig");
const McpServer = tool_mod.McpServer;
const PermissionHandler = tool_mod.PermissionHandler;

/// Oldest tested CLI; checked by `just canary`, not `Client.open`.
pub const min_cli_version = "2.1.228";

pub const PermissionMode = enum {
    manual,
    auto,
    dont_ask,
    accept_edits,
    /// Bypasses permissions and allowlists; grants host access. Isolate the environment.
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
    /// CLI path or name resolved through PATH.
    claude_path: []const u8 = "claude",
    cwd: std.process.Child.Cwd = .inherit,
    /// Skips discovery and setup; requires ANTHROPIC_API_KEY instead of CLI login.
    /// Tools and `/skill-name` remain available; configure access separately.
    bare: bool = false,
    /// Emits token deltas as `stream_event` messages.
    include_partial_messages: bool = true,
    model: ?[]const u8 = null,
    /// Permission rule syntax, for example `Read,Edit,Bash(git diff *)`.
    allowed_tools: ?[]const u8 = null,
    permission_mode: ?PermissionMode = null,
    append_system_prompt: ?[]const u8 = null,
    /// Path to an MCP config file, or an inline JSON object.
    mcp_config: ?[]const u8 = null,
    /// Built-in tool list; null keeps all. Include `Skill` for skill invocation.
    tools: ?[]const u8 = null,
    /// Comma-separated `user`, `project`, `local`; null uses CLI defaults.
    /// `user` loads ~/.claude/skills/; `project` loads .claude/skills/ from cwd to repo root.
    setting_sources: ?[]const u8 = null,
    /// Extra directories contribute `.claude/skills/`, excluding commands and agents.
    add_dirs: []const []const u8 = &.{},
    /// Plugin directories providing skills, subagents, hooks, and MCP servers.
    plugin_dirs: []const []const u8 = &.{},
    /// Subagent definitions as a JSON object.
    agents_json: ?[]const u8 = null,
    /// Disables skills and commands.
    disable_slash_commands: bool = false,
    /// Ignore every MCP source except `mcp_config`.
    strict_mcp_config: bool = false,
    max_turns: ?u32 = null,
    /// Invocation allowlist; discovery and `system/init` remain unfiltered.
    /// Null allows all; empty allows none. Slice and strings are borrowed until `close`.
    skills: ?[]const []const u8 = null,
    /// In-process MCP servers; slice and referenced data are borrowed until `close`.
    sdk_mcp_servers: []const McpServer = &.{},
    resume_session_id: ?[]const u8 = null,
    /// Handles unresolved permission prompts in `Client.next`; null keeps CLI refusal.
    /// Enables both `--permission-prompt-tool stdio` and `--permission-prompts host`.
    permission_handler: ?PermissionHandler = null,
    /// Opaque context passed to `permission_handler`.
    permission_context: ?*anyopaque = null,
    /// Appended verbatim after generated flags.
    extra_args: []const []const u8 = &.{},

    /// Stdin frame deadline after acquiring the write lock, including initialization.
    /// Timeout is terminal; zero is invalid.
    write_timeout_ms: u32 = 5_000,
    /// Grace before `kill` escalates SIGTERM to SIGKILL.
    termination_grace_ms: u32 = 250,
    stdout_buffer_size: usize = 64 * 1024,
    stdin_buffer_size: usize = 16 * 1024,
    /// Inclusive line limit; overflow returns `ProtocolTooLong` and skips to newline.
    /// Zero fails `open` with `InvalidMaxLineBytes`.
    max_line_bytes: usize = 32 * 1024 * 1024,

    /// Whether servers, skills (including empty), or permissions require initialization.
    pub fn needsInitialize(options: Options) bool {
        return options.sdk_mcp_servers.len > 0 or
            options.skills != null or
            options.permission_handler != null;
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
    if (options.permission_handler != null) {
        try argv.appendSlice(arena, &.{ "--permission-prompt-tool", "stdio", "--permission-prompts", "host" });
    }
    try argv.appendSlice(arena, options.extra_args);

    return argv.toOwnedSlice(arena);
}

// --- tests ---

// `buildArgv` is internal to the library; public option tests live in tests/.

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
    for (argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--bare"));
}

fn contains(argv: []const []const u8, flag: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

test "the default argv is the bare protocol and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv(arena.allocator(), .{});
    const expected = [_][]const u8{
        "claude",
        "--print",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
    };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "every flag-emitting field emits its flag" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const argv = try buildArgv(arena.allocator(), .{
        .claude_path = "/opt/bin/claude",
        .bare = true,
        .include_partial_messages = false,
        .model = "claude-sonnet-4-6",
        .allowed_tools = "Read",
        .permission_mode = .bypass_permissions,
        .append_system_prompt = "Be brief.",
        .mcp_config = "{\"mcpServers\":{}}",
        .tools = "Read,Skill",
        .setting_sources = "user",
        .add_dirs = &.{"../a"},
        .plugin_dirs = &.{"/p"},
        .agents_json = "{\"reviewer\":{}}",
        .disable_slash_commands = true,
        .strict_mcp_config = true,
        .max_turns = 3,
        .resume_session_id = "sess-1",
        .permission_handler = stubPermissionHandler,
    });

    try std.testing.expectEqualStrings("/opt/bin/claude", argv[0]);
    try std.testing.expect(contains(argv, "--bare"));
    try std.testing.expect(!contains(argv, "--include-partial-messages"));
    try std.testing.expect(containsPair(argv, "--model", "claude-sonnet-4-6"));
    try std.testing.expect(containsPair(argv, "--allowedTools", "Read"));
    try std.testing.expect(containsPair(argv, "--permission-mode", "bypassPermissions"));
    try std.testing.expect(containsPair(argv, "--append-system-prompt", "Be brief."));
    try std.testing.expect(containsPair(argv, "--mcp-config", "{\"mcpServers\":{}}"));
    try std.testing.expect(containsPair(argv, "--tools", "Read,Skill"));
    try std.testing.expect(containsPair(argv, "--setting-sources", "user"));
    try std.testing.expect(containsPair(argv, "--add-dir", "../a"));
    try std.testing.expect(containsPair(argv, "--plugin-dir", "/p"));
    try std.testing.expect(containsPair(argv, "--agents", "{\"reviewer\":{}}"));
    try std.testing.expect(contains(argv, "--disable-slash-commands"));
    try std.testing.expect(contains(argv, "--strict-mcp-config"));
    try std.testing.expect(containsPair(argv, "--max-turns", "3"));
    try std.testing.expect(containsPair(argv, "--resume", "sess-1"));
    try std.testing.expect(containsPair(argv, "--permission-prompt-tool", "stdio"));
    try std.testing.expect(containsPair(argv, "--permission-prompts", "host"));
}

test "the permission-prompt flags follow the handler, not the mode" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const without = try buildArgv(arena.allocator(), .{ .permission_mode = .manual });
    try std.testing.expect(!contains(without, "--permission-prompts"));
    try std.testing.expect(!contains(without, "--permission-prompt-tool"));

    const with = try buildArgv(arena.allocator(), .{ .permission_handler = stubPermissionHandler });
    // Both flags are required to receive host permission prompts.
    try std.testing.expect(containsPair(with, "--permission-prompt-tool", "stdio"));
    try std.testing.expect(containsPair(with, "--permission-prompts", "host"));
    try std.testing.expect((Options{ .permission_handler = stubPermissionHandler }).needsInitialize());
}

fn stubPermissionHandler(_: ?*anyopaque, _: Allocator, _: []const u8, _: std.json.Value) anyerror!tool_mod.PermissionDecision {
    return .allow;
}

test "extra_args land after every generated flag" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const extra = [_][]const u8{ "--first-extra", "--second-extra", "value" };
    const argv = try buildArgv(arena.allocator(), .{
        .bare = true,
        .model = "m",
        .allowed_tools = "Read",
        .permission_mode = .plan,
        .append_system_prompt = "p",
        .mcp_config = "c",
        .tools = "t",
        .setting_sources = "s",
        .add_dirs = &.{"d"},
        .plugin_dirs = &.{"p"},
        .agents_json = "a",
        .disable_slash_commands = true,
        .strict_mcp_config = true,
        .max_turns = 1,
        .resume_session_id = "r",
        .permission_handler = stubPermissionHandler,
        .extra_args = &extra,
    });

    try std.testing.expect(argv.len > extra.len);
    const tail = argv[argv.len - extra.len ..];
    for (extra, tail) |want, got| try std.testing.expectEqualStrings(want, got);
    for (argv[0 .. argv.len - extra.len]) |arg| {
        try std.testing.expect(!std.mem.startsWith(u8, arg, "--first-extra"));
    }
}
