# claude_agent_zig

A Claude Agent SDK client for Zig 0.16, built on the Claude Code CLI
`stream-json` protocol.

## Why this shape

Anthropic ships the Agent SDK as a Python package and a TypeScript package
only. The docs are explicit that other languages should drive the same agent
loop by running the CLI as a subprocess. Both official SDKs are themselves
wrappers around:

```
claude --print --input-format stream-json --output-format stream-json --verbose
```

That combination is a bidirectional, newline-delimited JSON protocol over the
child process pipes. Each line written to stdin is one user turn. Each line
read from stdout is one event. This client implements that protocol, so it gets
the real agent loop, tool use, subagents, MCP, hooks, skills, and sessions,
without reimplementing any of them.

The tradeoff is that `claude` must be installed and on PATH (or named
explicitly).

## Tools

Three layers, all supported.

**Built-in tools** (Read, Edit, Bash, Glob, Grep, WebSearch, WebFetch, Agent,
Skill, and the rest) run inside the CLI. Nothing to implement; scope them with
`allowed_tools`, `tools`, and `permission_mode`.

Note that `bare` narrows the built-in set to the shell and file tools, so
WebSearch, WebFetch, Agent and Skill are simply not registered in a bare
session. It defaults to off here for that reason.

**Skills** are filesystem artifacts the CLI discovers and runs. Neither the
official SDKs nor this one register them programmatically: you author a
`SKILL.md` on disk and the CLI finds it. What a client actually controls is
discovery, scoping, and dispatch, all of which are here:

- `setting_sources` governs discovery. `"user"` picks up `~/.claude/skills/`,
  `"project"` picks up `.claude/skills/` in the working directory and every
  parent up to the repository root.
- `add_dirs` contributes each directory's `.claude/skills/`, though not its
  commands or agents.
- `plugin_dirs` loads plugins, which can carry skills, subagents, hooks, and
  MCP servers together.
- Skills invoke through the `Skill` tool, so it needs an allow rule, and if you
  pass a `tools` list it must include `"Skill"`.
- `sendCommand("security-check", "src/")` dispatches a skill by name. Dispatch
  is just prompt text, so `send("/security-check src/")` is identical. Note
  that `skills` does not gate this path: an explicit `/name` still runs even
  when the name is outside the allowlist, which only constrains the skills
  Claude picks up on its own.
- The `system/init` event carries `skills` and `slash_commands` arrays.
  `event.arrayContains("skills", "security-check")` confirms a skill loaded
  before the session starts working, which is worth doing when a missing skill
  would be an expensive silent no-op.

`bare` disables skill discovery outright, which is the other reason it now
defaults to off.

`skills` restricts which discovered skills Claude may invoke on its own. It is
an invocation allowlist rather than a discovery filter: `system/init` still
reports every skill the CLI found, but one outside the list is not offered to
the model. An explicit `/name` dispatch bypasses it. It rides the `initialize`
control request as an array of strings, not a CLI flag.

Null and empty differ, so the option is `?[]const []const u8`:

```zig
.skills = null,                    // every discovered skill (field omitted)
.skills = &.{},                    // none
.skills = &.{ "code-review" },     // only this one
```

**Out-of-process MCP servers** attach through `mcp_config`, exactly as they do
for the CLI.

**In-process tools** are Zig functions the agent can call. Register them as an
`McpServer` and the CLI routes calls back over the control protocol on the same
stdin/stdout pipe, so no subprocess and no socket is involved:

```zig
fn addNumbers(_: ?*anyopaque, arena: Allocator, args: std.json.Value) !agent.ToolResult {
    // ...
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{a + b}) };
}

const tools = [_]agent.Tool{.{
    .name = "add",
    .description = "Add two numbers.",
    .input_schema =
    \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}
    ,
    .handler = addNumbers,
    .context = @ptrCast(&my_state),
}};

const servers = [_]agent.McpServer{.{ .name = "host", .tools = &tools }};
```

Claude sees these as `mcp__host__add`, so the allow rule is `mcp__host__*`.
Handlers run on the caller's thread, inside `next()`, between two conversation
events. Because tool calls come back over stdin, **stdin must stay open for the
whole turn**: call `closeStdin` after the `result` event, not before.

## Layout

- `src/agent.zig` is the client. No dependencies beyond the standard library.
- `src/main.zig` is a demo that streams one turn to stdout.

## Usage

```zig
const client = try agent.Client.open(gpa, io, .{
    .allowed_tools = "Read,Glob,Grep,mcp__host__*",
    .permission_mode = .accept_edits,
    .model = "claude-sonnet-4-6",
    .sdk_mcp_servers = &servers,
});
defer _ = client.close();

try client.send("Summarize README.md");

while (try client.next()) |event| {
    var e = event;
    defer e.deinit();
    if (e.textDelta()) |text| try out.writeAll(text);
    if (e.kind == .result) client.closeStdin();
}
```

Multi-turn conversations skip `closeStdin` entirely, read events until a
`result` arrives, then call `send` again on the same client. Calling `send`
while a turn is still in flight is also valid; the CLI treats it as mid-turn
guidance.

## Notes on the implementation

- `Client` is heap allocated because `Io.File.Reader` and `Io.File.Writer`
  embed the `Io.Reader` and `Io.Writer` interfaces that the vtable recovers
  with `@fieldParentPtr`. A stable address keeps that honest.
- Lines are read with `streamDelimiterLimit` into an `Io.Writer.Allocating`,
  so a single event larger than the read buffer is handled without a fixed cap.
  End of stream is detected by an empty reader buffer, since
  `streamDelimiterLimit` leaves the delimiter buffered on a successful line.
- Events are parsed to `std.json.Value` rather than to fixed structs. The event
  schema gains fields regularly, and a strict struct would break on the next
  CLI release. Typed accessors sit on top.
- `--bare` defaults to off, so a session picks up project configuration and
  works with an existing `claude` login. Turning it on skips discovery of
  hooks, plugins, MCP servers, auto memory, and `CLAUDE.md`, and in that mode
  `ANTHROPIC_API_KEY` must be set.
- stderr is inherited so CLI startup warnings stay visible. Change to `.pipe`
  if the host needs to capture them.
- The control channel is pumped only while the caller is inside `next()`. That
  is fine for a turn-driven loop, since the caller is always there while the
  agent is working, but a host that wants to service tool calls from another
  thread needs its own reader task.
- The `mcp_response` wrapper on tool replies is load-bearing and undocumented.
  Omit it and the CLI never matches the reply to its request; it stalls until
  its own timeout.
- Permission callbacks are not implemented. `--permission-prompt-tool stdio`
  routes prompts through this same control channel as a `permission` request,
  so it slots into `serveControlRequest` the same way `mcp_message` does.
  Until then, pre-authorize with `allowed_tools` or a permission mode; an
  unsupported control request gets an error response rather than silence, so
  the CLI does not hang.

## Build

```
zig build
zig build test
CLAUDE_BIN=claude zig build run -- "explain this repo"
```
