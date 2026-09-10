# claude_agent_zig

Claude Agent SDK client for Zig 0.16, built on the Claude Code CLI
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
explicitly). The oldest CLI this protocol has been exercised against is
`agent.min_cli_version` (`2.1.228`); nothing probes the installed binary at
`open`, since that would cost a second spawn per session, so `just canary`
checks the floor instead, once, against the CLI actually on PATH.

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

`input_schema` is spliced into the `tools/list` reply verbatim rather than
re-encoded, so `open` checks that every schema parses as JSON and is an object
before it allocates or spawns anything, and returns `error.InvalidToolSchema`
otherwise. A schema assembled at runtime therefore fails at `open`, where the
caller can see it, rather than as a corrupted protocol frame the CLI stalls on
mid-session.

Claude sees these as `mcp__host__add`, so the allow rule is `mcp__host__*`.
Handlers run on the caller's thread, inside `next()`, between two conversation
events. A handler may call `send`, `sendCommand`, `interrupt`, or `kill` on the
client, but not `next`: the lock `next` runs under is not reentrant. Because
tool calls come back over stdin, **stdin must stay open for the whole turn**:
call `closeStdin` after the `result` event, not before.

A handler's text is capped at `agent.max_tool_result_bytes` (16 KiB). Return
more and the model gets an `is_error` result saying the output was too long,
rather than the payload. The cap is not arbitrary: the reply is written to the
child's stdin from inside `next()`, so a reply larger than the pipe buffer
blocks there while the child blocks writing stdout that nothing is draining —
both processes wedge. A watchdog thread could `kill` its way out, but a host
driving the client from one thread has no such thread, and Zig 0.16 has no
non-blocking or readiness primitive for a child pipe, so a ceiling below the
smallest plausible pipe buffer is the fix.
A tool with more to say should return a summary, or write the payload
somewhere the agent can read with its own file tools.

The bound that is actually enforced is on the whole rendered reply line —
envelope, request ids and newline included — at `max_tool_result_bytes` plus
512 bytes of headroom, 16 896 bytes in all, because that is what lands in the
pipe. It applies to every reply that carries caller- or CLI-sized data, not
only tool results: an `initialize` or `tools/list` reply that does not fit
(roughly seventeen tools with 1 KiB schemas) is answered with a JSON-RPC
`-32603` error naming the size and the bound, rather than a body of the wrong
shape that would register nothing and say nothing.

**Permission prompts.** The CLI asks before running a tool that nothing
pre-authorized: one outside `allowed_tools`, under a permission mode that
prompts rather than refuses. Set `Options.permission_handler` and the client
passes `--permission-prompt-tool stdio`, which is what makes the CLI emit each
prompt as a `can_use_tool` control request on this pipe, together with
`--permission-prompts host`, which the CLI's `--help` documents as naming the
SDK host as the answerer. Both are sent because the second alone does nothing
observable: measured against CLI 2.1.261, a session carrying only
`--permission-prompts host` blocks the call and emits no request. A handler
also makes the client open with the `initialize` handshake, as the official
SDK does. Each prompt then arrives carrying `tool_name` and `input`, and `next()`
calls the handler on the caller's thread, under the same contract as a tool
handler: the arena is reset before each dispatch, `permission_context` is
passed through untouched, and `input` is the proposed tool input as a
`std.json.Value`, or JSON `null` when the request carried none.

```zig
fn decide(_: ?*anyopaque, _: Allocator, tool_name: []const u8, input: std.json.Value) !agent.PermissionDecision {
    _ = input;
    if (std.mem.eql(u8, tool_name, "Bash")) {
        return .{ .deny = "The shell is off in this session; use Read and Grep instead." };
    }
    return .allow;
}
```

The handler returns one of three decisions, each answered as a `success`
control response:

- `.allow` runs the tool with the input it was proposed with. The reply is
  `{"behavior":"allow","updatedInput":<input>}`; the input is echoed because
  that is the shape the official SDKs send and the CLI reads `updatedInput` as
  the input to run with.
- `.allow_with_input = "<json object>"` runs it with that input instead. The
  string is spliced into the reply raw, so it is validated first: a value that
  is not a JSON object becomes a deny rather than a corrupted frame. Build it
  with a serializer.
- `.deny = "<message>"` refuses the call; the reply is
  `{"behavior":"deny","message":"..."}` and the text is shown to the model, so
  say what to do instead, not only that the call was refused.

A handler that returns an error is answered as a deny carrying the error's
name; `error.OutOfMemory` is answered as a deny and then propagated from
`next()`, since that is a host condition rather than a decision. A request
without `tool_name` gets a control error, and without a handler installed a
`can_use_tool` request still gets the `unsupported control request` error
reply it always did, so the CLI does not hang either way.

The reply is bounded like a tool result, because it carries the tool input
back and that is as large as the CLI made it: an allow whose rendered line
exceeds 16 896 bytes is turned into a deny naming the size and the bound. In
practice that means a `Write` of more than about 16 KiB of content through a
prompting session is denied with an explanatory message the model can act on;
pre-authorize such tools with `allowed_tools` if that matters.

`allowed_tools` and `permission_mode` compose with the handler rather than
compete with it: only calls the two do not already settle reach the handler,
so the routine can be pre-authorized and the rest decided in code. The demo
installs a log-and-allow handler when `AGENT_PERMISSIONS=host` is set.

The handler path is verified against scripted stub CLIs over real pipes and,
once, end to end against CLI 2.1.261: a session opened with
`permission_mode = .manual`, `tools = "Bash"`, and a log-and-allow handler was
asked to run `mkdir -p` and a redirect, the CLI raised one `can_use_tool`
request for it, the handler's allow was honoured, and the directory and file
existed afterwards. Two things about that run matter when reproducing it. A
command Claude Code treats as read-only, such as a bare `echo`, never prompts
at all, so it cannot exercise the handler; and a settings source that sets
`permissions.defaultMode` to `auto` settles the call before any prompt, so
the demo's `--setting-sources user,project` picks that up from a user file
that has it. Pass `permission_mode` explicitly, or a narrower
`setting_sources`, when the handler has to see the prompt.

## Layout

No dependencies beyond the standard library.

Three directories, by role: `src/` is the library, `examples/` is the demo,
`tests/` is the black-box suite.

| File | |
|---|---|
| `src/agent.zig` | Public surface. Re-exports the types below; import just this. |
| `src/options.zig` | `Options`, `PermissionMode`, `min_cli_version`, and the CLI flags they become. |
| `src/event.zig` | `Event` and `Kind`: one protocol line, and how to read it. |
| `src/tool.zig` | `Tool`, `ToolResult`, `McpServer`, and the permission handler types. |
| `src/protocol.zig` | The wire format — every line this process writes to the CLI. |
| `src/client.zig` | `Client`: process lifecycle, the read loop, control dispatch. |
| `examples/demo.zig` | Demo that streams one turn to stdout. |
| `examples/demo_tools.zig` | The two example tools that demo exposes, and its permission handler. |
| `tests/all.zig` | Test root for the suite below; lists each file with `_ =`. |
| `tests/client_test.zig` | The public shape of `Client` and the re-export surface. |
| `tests/event_test.zig` | `Event` accessors, over fixed protocol lines. |
| `tests/integration_test.zig` | The real client against scripted stub CLIs: lifecycle, tool calls, framing. |
| `tests/options_test.zig` | `Options` and `PermissionMode` on the public surface. |
| `tests/tool_test.zig` | `Tool`, `ToolResult`, `McpServer` defaults and lookup. |

The table is exact by construction: `just docs-check` fails when it and the
tree under those three directories disagree, so it can only list them. The
read-loop benchmark lives outside them, in `bench/`, and is listed with the
rest of the tooling under Build below.

`build.zig` exposes `src/agent.zig` as a module named `agent`, which is how
`examples/`, `tests/` and `bench/` reach the library — a Zig file belongs to
exactly one module, so a root outside `src/` cannot import upward by relative
path.

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

`try client.next()` is the short form. Two of its errors cost one line, not
the stream, and a host that wants to keep reading can, with something to log:

```zig
const event = client.next() catch |err| switch (err) {
    // The line is still in the buffer until the next call, so log it now.
    error.InvalidJson => { try log.print("bad line: {s}\n", .{client.lastLine()}); continue; },
    // The CLI refused this client's own `initialize` or `interrupt`; the
    // stream is intact, but a refused `initialize` means no SDK tools.
    error.ControlRequestRejected => { try log.print("refused: {s}\n", .{client.lastControlError().?}); continue; },
    else => return err,
};
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

`kill()` is the escape hatch, and the deadline is the caller's to set, since
only the host knows what "too long" means for its workload. It sends the child
`SIGTERM` and reaps it, and it is safe to call from a watchdog thread while
another thread sits in `close` or `wait`, which is the shape that bounds a
`close`: the watchdog signals the child by pid, and the thread already inside
the reap observes the death and returns. There is exactly one reap, so `term`
is always the status the kernel reported, never an assumption. `killed` says
the signal was sent; a child that trapped it and exited cleanly is `killed`
with an `.exited` term.

```zig
const watchdog = try std.Thread.spawn(.{}, struct {
    fn run(c: *agent.Client, io: std.Io) void {
        io.sleep(.fromSeconds(30), .awake) catch {};
        c.kill(); // a no-op if the child was reaped in the meantime
    }
}.run, .{ client, io });
defer watchdog.join();
_ = try client.wait(); // returns within the deadline, one way or the other
```

The same holds for a thread blocked inside `next`: the client owns the child's
stdout descriptor for its whole life and closes it only in `close`, so a reap
on another thread never pulls the descriptor out from under a read. The child
dying is what ends the read, as end of stream.

The deadline still has to come from another thread, because Zig 0.16's `Io`
vtable exposes no timed or cancellable child wait: within one thread there is
no way to bound `close`, as the thread that would enforce the deadline is the
one already blocked. That is a constraint of the platform, not of the client.

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
- `lastLine()` returns the raw bytes of the most recent protocol line, whatever
  became of it: the line behind the event `next()` returned, the line that
  failed to parse behind `error.InvalidJson`, or the prefix that fit before
  `error.ProtocolTooLong` cut the rest off. It is empty before the first read
  and after end of stream, and valid only until the next call to `next()`,
  which reuses the buffer.
- The line buffer and the scratch arena behind tool dispatch keep their
  capacity up to 1 MiB, so the usual small line costs no allocation, and are
  released past it. One event near `max_line_bytes` (32 MiB by default) no
  longer pins that much memory for the rest of the session.
- Events are parsed to `std.json.Value` rather than to fixed structs. The event
  schema gains fields regularly, and a strict struct would break on the next
  CLI release. Typed accessors sit on top. `Kind` is exhaustive on purpose:
  `unknown` already absorbs every wire type it does not name, so a non-
  exhaustive `_` tag would never be produced; the cost is that a new named
  variant is a source-breaking change for a `switch (e.kind)` that names every
  arm, so write an `else` arm.
- `control_response` lines — the CLI answering this client's own `initialize`
  and `interrupt` requests — are matched by id rather than discarded. A
  success carries nothing the caller needs; an error is returned from `next()`
  as `error.ControlRequestRejected` with the CLI's text in
  `lastControlError()`. The stream stays readable, but a refused `initialize`
  means the session has no SDK tools and no skill allowlist, whatever
  `Options` asked for, and the first symptom otherwise would be the model
  reporting it cannot find a tool.
- `--bare` defaults to off, so a session picks up project configuration and
  works with an existing `claude` login. Turning it on skips hooks, LSP, plugin
  sync, auto memory, and `CLAUDE.md` auto-discovery, and in that mode
  `ANTHROPIC_API_KEY` must be set. It is not a tool boundary; see the note
  under Tools.
- `--verbose` is always passed. The streaming protocol requires it, and
  `extra_args` is appended after the generated flags, so it cannot be removed.
  Combined with inherited stderr, CLI diagnostics reach the host's terminal.
  The argv is built in an arena that is freed as soon as `spawn` returns; the
  child retains no reference to it.
- stderr is inherited so CLI startup warnings stay visible. Change to `.pipe`
  if the host needs to capture them.
- `WriteError` is exactly `error{ StdinClosed, WriteFailed }`. No write path
  allocates: `send` and `interrupt` render straight into the stdin writer's
  buffer and `sendCommand` streams its text in escaped pieces, so an
  allocation error would be a lie about the behaviour.
- The control channel is pumped only while the caller is inside `next()`. That
  is fine for a turn-driven loop, since the caller is always there while the
  agent is working. A host that wants tool calls serviced while it does other
  work keeps one thread in `next` and drives the rest from others.
- `Client` is thread safe. Any method may be called from any thread,
  concurrently with any other, under two rules. `next` is single-consumer:
  concurrent calls serialize rather than corrupt, and a handler must not call
  it from inside `next`, since the lock is not reentrant. `close` must be the
  last call, like a free. Three locks back this, one per concern, and none is
  held across a blocking call it does not own: whole lines on stdin — `send`,
  `sendCommand`, `interrupt`, `closeStdin`, and the control replies `next`
  writes — are serialized against each other, so two writers cannot interleave
  on the pipe; `next` holds a read lock for the line, the arena, and the
  dispatch; and the lifecycle fields sit under a third. That is what makes
  `interrupt` usable: abandoning an in-flight turn means calling it while
  another thread sits in `next`, and it is safe to.
- `lastLine` and `lastControlError` belong to the thread that called `next`,
  valid until that thread's next call. `sessionId` is safe from any thread.
  The public status fields — `term`, `killed`, `wait_error`, `flush_error` —
  are stable once the caller's own `wait`, `kill`, or `closeStdin` has
  returned; another thread reads the status safely through `wait`, which
  returns the cached value once the child is reaped.
- `Options` slices are borrowed, not copied. `sdk_mcp_servers` and `skills`
  are held by pointer for the life of the client, so whatever backs them has
  to outlive it. A local array in the function that calls `open` is the easy
  mistake: the handshake happens inside `open` while the frame is still alive,
  so the session starts cleanly and only misbehaves later, when a tool call
  reads freed stack. Give them the same lifetime as the client.
- The `mcp_response` wrapper on tool replies is load-bearing and undocumented.
  Omit it and the CLI never matches the reply to its request; it stalls until
  its own timeout.
- Permission prompts are routed to this process only when
  `Options.permission_handler` is set; see Tools. Without one the CLI keeps
  its own handling, where a call nothing pre-authorized is refused, and a
  `can_use_tool` request that arrives anyway gets an error response rather
  than silence, so the CLI does not hang.

## Platforms

macOS and Linux are the supported platforms, and both are verified: the suite
runs on macOS (Apple Silicon) and the tree cross-compiles cleanly with
`zig build -Dtarget=x86_64-linux`. The library itself is plain `std`, but two
things around it are POSIX-shaped: the demo reads its arguments with
`init.minimal.args.iterate()` (`examples/demo.zig`), which Zig rejects on
Windows in favour of `initAllocator`, so `zig build -Dtarget=x86_64-windows`
fails there; and the black-box suite and the benchmark drive the client
through `#!/bin/sh` stub CLIs written at runtime, so they need a Bourne shell
at `/bin/sh`. Windows is therefore not supported.

## Build

```
zig build
zig build test
CLAUDE_BIN=claude zig build run -- "explain this repo"
zig build bench -- 100000    # read-loop benchmark, ReleaseFast via `just bench`
zig build docs               # autodocs for the agent module into zig-out/docs/
```

`build.zig` refuses any Zig other than the one `build.zig.zon` names
(`0.16.0`): the manifest's `minimum_zig_version` is only a floor, and a later
toolchain would otherwise be accepted there and fail somewhere inside `std`
instead of at the first line of the build.

A `justfile` wraps the same commands and is the usual entry point. `just`
alone lists every recipe:

```
just build                        # zig build
just test                         # zig build test
just test-release                 # zig build test -Doptimize=ReleaseSafe
just dev "explain this repo"      # build and run one turn
just ci                           # fmt-check + docs-check + test + test-release + build, the gate
just canary                       # check the CLI meets the version floor and accepts what we emit
just ci-full                      # ci plus the canary
just bench [lines]                # Client.next() over a synthetic stream, ReleaseFast
just docs                         # autodocs into zig-out/docs/
just release <version>            # dist/: tarball, SHA256SUMS, SBOM, optional signature
just release-verify <version>     # check dist/ sums, and the signature when configured
just canary-schedule-install      # run the canary weekly (launchd on macOS)
just canary-schedule-uninstall    # remove that schedule
```

The tooling files, none of which are part of the package:

| File | |
|---|---|
| `build.zig` | The build graph: the `agent` module, the demo, three test roots, `bench`, `docs`, and the exact-Zig-version guard. |
| `justfile` | Every recipe above. |
| `bench/next_bench.zig` | Streams a synthetic `stream_event` transcript through `next()` over a real pipe and reports events/s, bytes and allocations per event. |
| `scripts/docs-check.sh` | The README-vs-tree gate: the Layout table must match `src/`, `examples/`, `tests/` exactly, and the Usage block must compile. |
| `scripts/release.sh` | Cuts `dist/` for a version; never tags, commits, or pushes. |
| `scripts/release-verify.sh` | Checks what `release.sh` left in `dist/`. |
| `.githooks/pre-commit` | `fmt-check` and `docs-check` on the working tree. |
| `.githooks/pre-push` | `just ci` on each commit being pushed, in a temporary worktree. |

**CI is strictly local, by design: there is no hosted CI and no workflow file.**
The gate is two git hooks under `.githooks/`, version-controlled rather than
hidden in `.git/hooks/`, and installed once per clone with `just hooks-install`
(which points `core.hooksPath` at the directory). `pre-commit` runs the fast
checks, formatting and the README drift check, on the working tree.
`pre-push` gates the commits actually leaving the machine: it checks each
pushed commit out into a temporary detached worktree, runs `just ci` there
with that commit's own `justfile`, and removes the worktree on every exit
path, so a dirty tree or a pushed side branch cannot make a green result mean
anything other than "this commit passes". Both hooks fail closed when `zig`
is missing, and both can be bypassed with `--no-verify`, which is the whole
CI this repository has. `just canary` is deliberately not part of `ci`: it
needs the `claude` binary and tests the installed CLI rather than the commit,
so it belongs in `ci-full`, before a release or after a CLI upgrade, and
`just canary-schedule-install` runs it weekly so drift is caught without
anyone remembering to.

Releases are cut locally too. `just release <version>` refuses a dirty tree, a
version that does not match `build.zig.zon`, or a version `CHANGELOG.md` has no
heading for; runs `just ci-full`; and writes `dist/`: a `git archive` tarball,
a minimal CycloneDX 1.5 SBOM, `SHA256SUMS` over both, and an `ssh-keygen`
signature of the sums when `RELEASE_SIGNING_KEY` names a key. It prints the
`git tag` command and stops; tagging and pushing the tag stay the owner's
decision. `just release-verify <version>` checks the sums and, when
`RELEASE_ALLOWED_SIGNERS` is set, the signature; without that variable it says
the signature was not checked rather than implying it was.

Depending on this package from another Zig project needs a tag to point at,
and no tag exists yet: `just release <version>` prints the `git tag` command
once the release artefacts are cut. Once one is pushed, the consumer side is:

```
zig fetch --save git+https://github.com/cipher-rc5/claude_agent_zig#v0.1.0
```

which records the URL and content hash in the consumer's `build.zig.zon`
(the package name is `claude_agent`, its `.fingerprint` is in this repository's
manifest), and in the consumer's `build.zig`:

```
const agent = b.dependency("claude_agent", .{ .target = target, .optimize = optimize }).module("agent");
exe.root_module.addImport("agent", agent);
```

Environment variables read by the demo: `CLAUDE_BIN` selects the CLI binary;
`AGENT_SKILLS` is a comma list restricting which skills the agent may invoke
on its own, where unset allows every discovered skill and the empty string
allows none; and `AGENT_PERMISSIONS=host` routes the CLI's permission prompts
to the demo's log-and-allow handler. The release scripts read
`RELEASE_SIGNING_KEY`, `RELEASE_ALLOWED_SIGNERS`, and the optional
`RELEASE_SIGNER_IDENTITY`.
