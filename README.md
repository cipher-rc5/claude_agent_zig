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

Note that `bare` is not a tool sandbox. Per the CLI's own description it skips
hooks, LSP, plugin sync, attribution, auto-memory, background prefetches,
keychain reads, and `CLAUDE.md` auto-discovery, and it forces authentication
through `ANTHROPIC_API_KEY` rather than an existing login. It does not
deregister WebSearch, WebFetch, or Agent. To actually constrain what the agent
may reach for, use `tools`, `allowed_tools`, and `permission_mode`; those are
the tool boundary, and `bare` is not.

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

`bare` skips `CLAUDE.md` auto-discovery and plugin sync, so it changes what a
session picks up from the filesystem. It does not disable skills outright: the
CLI states that skills still resolve via `/skill-name` in a bare session. It
defaults to off here so a session inherits project configuration and an
existing `claude` login.

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
    // ... parse `a` and `b` out of `args`, reporting bad input as
    // `.{ .text = "...", .is_error = true }` rather than failing the turn.
    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{a + b}) };
}

const tools = [_]agent.Tool{.{
    .name = "add",
    .description = "Add two numbers. Send each as a decimal string so " ++
        "large integers stay exact.",
    .input_schema =
    \\{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"}},"required":["a","b"]}
    ,
    .handler = addNumbers,
    .context = @ptrCast(&my_state),
}};

const servers = [_]agent.McpServer{.{ .name = "host", .tools = &tools }};
```

The operands are declared as strings rather than numbers on purpose. A JSON
`number` is an IEEE 754 double by the time it reaches the wire, so an argument
above 2^53 arrives already rounded no matter how exact the handler is —
measured against the CLI, `{"type":"integer"}` rounds exactly the same way. A
decimal string is the only shape that survives the round trip, so a tool that
cares about exactness asks for one and parses it itself. `examples/demo_tools.zig`
carries the worked version, including what it rejects.

Claude sees these as `mcp__host__add`, so the allow rule is `mcp__host__*`.
Handlers run on the caller's thread, inside `next()`, between two conversation
events. Because tool calls come back over stdin, **stdin must stay open for the
whole turn**: call `closeStdin` after the `result` event, not before.

A handler's text is capped at `agent.max_tool_result_bytes` (16 KiB). Return
more and the model gets an `is_error` result saying the output was too long,
rather than the payload. The cap is not arbitrary: the reply is written to the
child's stdin from inside `next()`, so a reply larger than the pipe buffer
blocks there while the child blocks writing stdout that nothing is draining —
both processes wedge, and `kill` is unreachable because the caller's thread is
inside `next()`. Zig 0.16 has no non-blocking or readiness primitive for a
child pipe, so a ceiling below the smallest plausible pipe buffer is the fix.
A tool with more to say should return a summary, or write the payload
somewhere the agent can read with its own file tools.

## Layout

No dependencies beyond the standard library.

Three directories, by role: `src/` is the library, `examples/` is the demo,
`tests/` is the black-box suite.

| File | |
|---|---|
| `src/agent.zig` | Public surface. Re-exports the types below; import just this. |
| `src/options.zig` | `Options`, `PermissionMode`, and the CLI flags they become. |
| `src/event.zig` | `Event` and `Kind`: one protocol line, and how to read it. |
| `src/tool.zig` | `Tool`, `ToolResult`, `McpServer`: in-process tools. |
| `src/protocol.zig` | The wire format — every line this process writes to the CLI. |
| `src/client.zig` | `Client`: process lifecycle, the read loop, control dispatch. |
| `examples/demo.zig` | Demo that streams one turn to stdout. |
| `examples/demo_tools.zig` | The two example tools that demo exposes. |
| `tests/all.zig` | Test root for the suite below; lists each file with `_ =`. |
| `tests/client_test.zig` | The public shape of `Client` and the re-export surface. |
| `tests/event_test.zig` | `Event` accessors, over fixed protocol lines. |
| `tests/integration_test.zig` | The real client against scripted stub CLIs: lifecycle, tool calls, framing. |
| `tests/options_test.zig` | `Options` and `PermissionMode` on the public surface. |
| `tests/tool_test.zig` | `Tool`, `ToolResult`, `McpServer` defaults and lookup. |

`build.zig` exposes `src/agent.zig` as a module named `agent`, which is how
`examples/` and `tests/` reach the library — a Zig file belongs to exactly one
module, so a root outside `src/` cannot import upward by relative path.

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

// A CLI that fails on startup produces no events at all, so the loop above
// ends normally and the exit status is the only thing that says otherwise.
// `wait` reports it; `close` still returns it for callers who only need the
// happy path.
switch (try client.wait()) {
    .exited => |code| if (code != 0) return error.AgentFailed,
    else => return error.AgentFailed,
}
```

**`close()` can block forever on a child that never exits.** Both `close` and
`wait` reap the child with an unbounded blocking wait, so the `defer _ =
client.close()` above returns only when the CLI actually exits. A CLI that is
hung but alive never returns an error from that wait — it simply does not
return — so nothing on this path times out and the host thread stays parked in
`close` indefinitely. This is a real constraint rather than an oversight: Zig
0.16's `Io` vtable exposes no timed or non-blocking child wait, and cancelling
a wait under `Io.Select` clears `child.id`, discarding the handle needed to
escalate afterwards.

The remedy is `kill()`, and the deadline is the caller's to set, since only the
host knows what "too long" means for its workload. Arm a timer or a watchdog
thread before entering the read loop and have it call `kill` when the deadline
passes; `kill` signals the child and reaps it, which releases the thread parked
in `close`. Note that `kill` synthesizes `.signal = TERM` rather than observing
a status, so read `killed` before branching on `term`. A host that cannot
tolerate a wedged child must arrange this itself — the plain `defer _ =
client.close()` idiom does not.

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
  works with an existing `claude` login. Turning it on skips hooks, LSP, plugin
  sync, auto memory, and `CLAUDE.md` auto-discovery, and in that mode
  `ANTHROPIC_API_KEY` must be set. It is not a tool boundary; see the note
  under Tools.
- `--verbose` is always passed. The streaming protocol requires it, and
  `extra_args` is appended after the generated flags, so it cannot be removed.
  Combined with inherited stderr, CLI diagnostics reach the host's terminal.
- stderr is inherited so CLI startup warnings stay visible. Change to `.pipe`
  if the host needs to capture them.
- The control channel is pumped only while the caller is inside `next()`. That
  is fine for a turn-driven loop, since the caller is always there while the
  agent is working, but a host that wants to service tool calls from another
  thread needs its own reader task.
- `Client` is not thread safe. Every method must be called from one thread:
  there is no lock, and `send` racing `next` interleaves two JSON objects on a
  single line, which the CLI reads as malformed protocol. This is why
  `interrupt` is of limited use in practice — abandoning an in-flight turn
  means calling it while another thread sits in `next`, which is exactly the
  race above. It is here for hosts that drive the client from their own reader
  task and can serialize the two.
- `Options` slices are borrowed, not copied. `sdk_mcp_servers` and `skills`
  are held by pointer for the life of the client, so whatever backs them has
  to outlive it. A local array in the function that calls `open` is the easy
  mistake: the handshake happens inside `open` while the frame is still alive,
  so the session starts cleanly and only misbehaves later, when a tool call
  reads freed stack. Give them the same lifetime as the client.
- The `mcp_response` wrapper on tool replies is load-bearing and undocumented.
  Omit it and the CLI never matches the reply to its request; it stalls until
  its own timeout.
- Permission callbacks are not implemented. A permission prompt would arrive as
  a control request with a subtype other than `mcp_message`, so it would slot
  into `serveControlRequest` the same way `mcp_message` does. (Earlier notes
  here cited a `--permission-prompt-tool` flag as the way to route them; no
  such flag exists in the CLI as of 2.1.228, so the exact mechanism is unknown
  and would need to be rediscovered against a version that supports it.) Until
  then, pre-authorize with `allowed_tools` or a permission mode; an unsupported
  control request gets an error response rather than silence, so the CLI does
  not hang.

## Build

```
zig build
zig build test
CLAUDE_BIN=claude zig build run -- "explain this repo"
```

A `justfile` wraps the same commands and is the usual entry point. `just`
alone lists every recipe:

```
just build                        # zig build
just test                         # zig build test
just dev "explain this repo"      # build and run one turn
just ci                           # fmt-check + test + build, the gate
just canary                       # check the CLI still accepts what we emit
just ci-full                      # ci plus the canary
```

CI is local. A git pre-push hook runs `just ci` and blocks a push whose tree
does not pass; install it once per clone with `just hooks-install`. The hook
lives in `.githooks/` rather than `.git/hooks/`, so it is version-controlled.
`just canary` is deliberately not part of `ci`: it needs the `claude` binary
and tests the installed CLI rather than the commit, so it belongs in
`ci-full`, before a release or after a CLI upgrade.

Two environment variables are read by the demo: `CLAUDE_BIN` selects the CLI
binary, and `AGENT_SKILLS` is a comma list restricting which skills the agent
may invoke on its own. Leaving `AGENT_SKILLS` unset allows every discovered
skill; setting it to the empty string allows none.
