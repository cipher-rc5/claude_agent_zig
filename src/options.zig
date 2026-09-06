// src/options.zig
// Session configuration, and the CLI flags it translates into.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tool_mod = @import("tool.zig");
const McpServer = tool_mod.McpServer;
const PermissionHandler = tool_mod.PermissionHandler;

/// The oldest `claude` CLI this protocol has been exercised against. Nothing
/// here probes the installed binary: `--version` would cost a spawn on every
/// `open`, doubling the process cost of a session to learn something that
/// does not change between sessions. `just canary` checks it instead, once,
/// against the CLI actually on PATH, alongside every flag `buildArgv` emits.
pub const min_cli_version = "2.1.228";

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
    /// Skip discovery: hooks, LSP, plugin sync, attribution, auto memory,
    /// background prefetches, keychain reads, and CLAUDE.md auto-discovery.
    /// Authentication is forced through ANTHROPIC_API_KEY rather than an
    /// existing `claude` login, so that variable must be set in the child's
    /// environment.
    ///
    /// NOT a tool boundary. It does not deregister WebSearch, WebFetch, Agent,
    /// or anything else built in, and skills still resolve via `/skill-name`.
    /// What constrains the agent is `allowed_tools`, `tools`, and
    /// `permission_mode`.
    ///
    /// Off by default, so a session inherits project configuration and an
    /// existing login.
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
    ///
    /// BORROWED, not copied. `Client.open` keeps this slice and the strings it
    /// points at, and re-reads them on every `initialize`, so both must stay
    /// valid until `Client.close`. A slice of a stack array in the scope that
    /// calls `open` is the usual way to get this wrong.
    skills: ?[]const []const u8 = null,
    /// In-process MCP servers. Tools live in this process and are reached
    /// over the control protocol, so no subprocess is involved.
    ///
    /// BORROWED, not copied. `Client.open` keeps this slice, and every tool
    /// call for the life of the session resolves its handler, context pointer,
    /// and schema through it, so it must stay valid until `Client.close`.
    /// Unlike most fields here, this outlives the `open` call by the whole
    /// session.
    sdk_mcp_servers: []const McpServer = &.{},
    /// Resume an existing session by id.
    resume_session_id: ?[]const u8 = null,
    /// Answers the CLI's permission prompts. When set, the client passes
    /// `--permission-prompt-tool stdio`, which is what makes the CLI emit each
    /// prompt as a `can_use_tool` control request on this pipe, and
    /// `--permission-prompts host`, which names this process as the answerer;
    /// `Client.next` dispatches the request here. Measured against CLI
    /// 2.1.261, `--permission-prompts host` alone emits nothing and the tool
    /// call is simply blocked, so both flags are sent, as the official SDK
    /// does. Leave null to keep the CLI's own behaviour, where a call nothing
    /// pre-authorized is refused.
    ///
    /// Only calls that `allowed_tools` and `permission_mode` do not already
    /// settle reach the handler, so the two compose: pre-authorize the
    /// routine, and decide the rest here.
    permission_handler: ?PermissionHandler = null,
    /// Passed through to `permission_handler` untouched.
    permission_context: ?*anyopaque = null,
    /// Appended verbatim after the flags this module generates.
    extra_args: []const []const u8 = &.{},

    stdout_buffer_size: usize = 64 * 1024,
    stdin_buffer_size: usize = 16 * 1024,
    /// Refuse to buffer a single protocol line larger than this. The boundary
    /// is inclusive: a line of exactly this many bytes is accepted, and one
    /// byte more is rejected with `error.ProtocolTooLong`, which costs that
    /// one line rather than the stream.
    ///
    /// Must not be zero. Every line, the empty one included, is larger than a
    /// zero-byte budget, so no line could ever be read; `Client.open` rejects
    /// it with `error.InvalidMaxLineBytes` rather than letting the read loop
    /// fail forever.
    max_line_bytes: usize = 32 * 1024 * 1024,

    /// Whether the session needs an `initialize` control request before the
    /// first turn. Skills being set at all counts, since an empty allowlist
    /// still has to be declared. A permission handler counts too: the
    /// official SDK always opens with `initialize` when it can answer
    /// prompts, and the handshake is what tells the CLI a host is listening.
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

// These exercise `buildArgv`, which is `pub` for client.zig but not re-exported
// by agent.zig, so moving them would widen the public surface. `containsPair`
// stays private for the same reason; tests/options_test.zig keeps its own copy.

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

fn contains(argv: []const []const u8, flag: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, flag)) return true;
    return false;
}

test "the default argv is the bare protocol and nothing else" {
    // Every optional flag is off by default except partial messages, so a
    // default session must not reach for a model, a permission mode, or a
    // config file the caller never named.
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
    // One case per field, so a field that silently stops reaching the argv
    // fails here by name rather than as a CLI that ignores a setting.
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
    // Routing prompts to a host that has nothing to answer them with would
    // leave every prompt unanswered, so the flag is tied to the handler.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const without = try buildArgv(arena.allocator(), .{ .permission_mode = .manual });
    try std.testing.expect(!contains(without, "--permission-prompts"));
    try std.testing.expect(!contains(without, "--permission-prompt-tool"));

    const with = try buildArgv(arena.allocator(), .{ .permission_handler = stubPermissionHandler });
    // Both, and stdio first: measured against CLI 2.1.261, `--permission-prompts
    // host` on its own emits no can_use_tool request at all.
    try std.testing.expect(containsPair(with, "--permission-prompt-tool", "stdio"));
    try std.testing.expect(containsPair(with, "--permission-prompts", "host"));
    // And a handler is enough to need the initialize handshake.
    try std.testing.expect((Options{ .permission_handler = stubPermissionHandler }).needsInitialize());
}

fn stubPermissionHandler(_: ?*anyopaque, _: Allocator, _: []const u8, _: std.json.Value) anyerror!tool_mod.PermissionDecision {
    return .allow;
}

test "extra_args land after every generated flag" {
    // The README promises `--verbose` cannot be removed because `extra_args`
    // comes after the generated flags. Every generated flag, not just the
    // protocol ones: a later flag that slipped behind `extra_args` would let a
    // caller's `--resume` be overridden by the generated one.
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

    // The tail of the argv is exactly `extra_args`, in order, and nothing
    // generated comes after it.
    try std.testing.expect(argv.len > extra.len);
    const tail = argv[argv.len - extra.len ..];
    for (extra, tail) |want, got| try std.testing.expectEqualStrings(want, got);
    for (argv[0 .. argv.len - extra.len]) |arg| {
        try std.testing.expect(!std.mem.startsWith(u8, arg, "--first-extra"));
    }
}
