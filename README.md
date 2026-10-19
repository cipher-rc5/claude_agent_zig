# claude_agent_zig

Claude Agent SDK client for Zig 0.17, built on the Claude Code CLI
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
before it spawns anything, and returns `error.InvalidToolSchema`
otherwise. Schemas may nest at most 128 containers. A schema assembled at
runtime therefore fails at `open`, where the
caller can see it, rather than as a corrupted protocol frame the CLI stalls on
mid-session.

Claude sees these as `mcp__host__add`, so the allow rule is `mcp__host__*`.
Handlers run on the caller's thread, inside `next()`, between two conversation
events. A handler may call `send`, `sendCommand`, `interrupt`, or `kill` on the
client, but not `next`: the lock `next` runs under is not reentrant. Because
tool calls come back over stdin, **stdin must stay open for the whole turn**:
call `closeStdin` after the final result and any background work finish.

A handler's text is capped at `agent.max_tool_result_bytes` (16 KiB). Larger
results become `is_error` replies. Every complete control reply, including
escaped content, ids, envelope, and newline, is limited to 16 896 bytes.
Oversized `initialize` and `tools/list` replies receive JSON-RPC errors;
oversized tool results receive failed-call results. A fallback follows the
same limit. Correlation ids are never truncated: if a correlated fallback
cannot fit, `next()` returns terminal `error.ReplyTooLong` and the transport
is disabled and the child is force-terminated. Return a summary or a reference
for larger tool outputs.

The size bound limits memory and protocol output; it does not guarantee that
a pipe write completes immediately. Pipe capacity varies. After acquiring the
write lock, pipe I/O uses
`Options.write_timeout_ms` (5 seconds by default), including initialization
during `open`. Waiting for the lock and synchronous host callbacks have no
API deadline. A timeout or partial write makes the transport terminal, so
later writes cannot silently continue a broken frame.
Use `terminate` to stop and reap the child after a transport failure.

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

Permission replies share the complete-frame limit. Oversized allows and denial
messages become short denials; correlation metadata that cannot fit returns
terminal `error.ReplyTooLong`. Large inputs can therefore require
pre-authorization through `allowed_tools`, rather than an echoed permission
reply.

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

Three directories, by role: `src/` is the library, `examples/` holds executable examples,
`tests/` is the black-box suite.

| File | |
|---|---|
| `src/agent.zig` | Public surface. Re-exports the types below; import just this. |
| `src/options.zig` | `Options`, `PermissionMode`, `min_cli_version`, and the CLI flags they become. |
| `src/event.zig` | `Event` and `Kind`: one protocol line, and how to read it. |
| `src/tool.zig` | `Tool`, `ToolResult`, `McpServer`, and the permission handler types. |
| `src/protocol.zig` | The wire format — every line this process writes to the CLI. |
| `src/client.zig` | `Client`: process lifecycle, the read loop, control dispatch. |
| `src/transport.zig` | Deadline-aware pipe I/O and termination cancellation. |
| `examples/demo.zig` | Demo that streams one turn to stdout. |
| `examples/demo_tools.zig` | The two example tools that demo exposes, and its permission handler. |
| `examples/streaming.zig` | Complete single-turn streaming and exit-status handling. |
| `examples/permissions.zig` | Complete permission allow/deny handling. |
| `examples/initialization.zig` | Complete initialization-rejection handling. |
| `examples/shutdown.zig` | A turn deadline, termination, and reader cleanup. |
| `tests/all.zig` | Test root for the suite below; lists each file with `_ =`. |
| `tests/client_test.zig` | The public shape of `Client` and the re-export surface. |
| `tests/event_test.zig` | `Event` accessors, over fixed protocol lines. |
| `tests/integration_test.zig` | The real client against scripted stub CLIs: lifecycle, tool calls, framing. |
| `tests/options_test.zig` | `Options` and `PermissionMode` on the public surface. |
| `tests/tool_test.zig` | `Tool`, `ToolResult`, `McpServer` defaults and lookup. |
| `tests/transport_contract_test.zig` | Public transport failure, cancellation, and fragmented framing contracts. |

The table is exact by construction: `just docs-check` fails when it and the
tree under those three directories disagree, so it can only list them. The
read-loop benchmark lives outside them, in `bench/`, and is listed with the
rest of the tooling under Build below.

`build.zig` exposes `src/agent.zig` as a module named `agent`, which is how
`examples/`, `tests/` and `bench/` reach the library — a Zig file belongs to
exactly one module, so a root outside `src/` cannot import upward by relative
path.

## Usage

One foreground turn with no background tasks:

```zig
const client = try agent.Client.open(gpa, io, .{
    .allowed_tools = "Read,Glob,Grep,mcp__host__*",
    .permission_mode = .accept_edits,
    .model = "claude-sonnet-4-6",
    .sdk_mcp_servers = &servers,
});
defer {
    _ = client.terminate(250) catch {};
    _ = client.close();
}

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

These foreground-only examples cover [streaming](examples/streaming.zig),
[permission decisions](examples/permissions.zig),
[initialization rejection](examples/initialization.zig), and
[bounded shutdown](examples/shutdown.zig). `zig build examples-check` compiles
all four without running a model request. They accept `CLAUDE_BIN` to select
the CLI; running one uses the CLI's normal authentication and billing.

`error.InvalidJson` and `error.ProtocolTooLong` discard one input line; a
caller may log `lastLine()` and keep reading. JSON nesting above 128 returns
terminal `error.ProtocolTooDeep` and stops the session. `error.InitializationRejected`
reports a rejected handshake, while `error.ControlRequestRejected` reports a
rejected interrupt. `lastControlError()` supplies the latest CLI rejection
diagnostic until another rejection replaces it or `close()` frees it. Initialization rejection leaves requested SDK tools
and skill restrictions unconfigured; stop the session if those are required.
`status().initialization` distinguishes pending, accepted, rejected, failed,
and sessions that did not require initialization. `open` sends the handshake
but does not wait for its acknowledgement; keep calling `next()` to process it.

An accepted interrupt cancels the current turn. The CLI may report
`error_during_execution` and exit 1; inspect `event.getString("terminal_reason")`
for `aborted_streaming` or `aborted_tools` to distinguish cancellation from
other failures. The result and exit status remain available to the caller.

`wait()` and `close()` wait for the child to exit, with no graceful-exit
deadline. Drain required events before reaping; output buffered after a reap
is discarded. Keep a reader active if the child still needs to write stdout. `terminate(grace_ms)` requests SIGTERM, escalates to SIGKILL after
the grace interval, and returns the observed exit status. `forceKill()` skips
the grace interval. `kill()` uses `Options.termination_grace_ms` (250 ms by
default) and discards any wait error; prefer `terminate` when errors matter.
These operations share one reaper and can run while another thread waits,
reads, or writes. Termination cancels pipe I/O before reaping, so a blocked
writer does not prevent escalation. Scheduler delays and an uninterruptible
kernel task can extend wall-clock completion beyond the configured grace.

Only the direct child is signaled. The host must not independently reap it
or enable automatic SIGCHLD reaping; SDK coordination assumes ownership of
that child's wait status. Hosts must also preserve the ignored SIGPIPE
disposition installed by the default `std.Io.Threaded` initialization so a
closed pipe returns a write error. Descendants can survive termination;
canceling SDK pipe I/O prevents their inherited descriptors from keeping the
client blocked, but does not kill those processes. Handlers run synchronously
inside the host and must return before their reader can finish. A handler that
never returns defeats a thread-join or `close()` deadline; use cooperative
cancellation or process isolation when hard callback deadlines are required.
Join every client-using thread before `close()` destroys the client.

Multi-turn conversations skip `closeStdin` entirely, read events until a
`result` arrives, then call `send` again on the same client. Calling `send`
while a turn is still in flight is also valid; the CLI treats it as mid-turn
guidance.

Background tasks can issue SDK tool calls after the foreground `result`.
Keep reading and track their lifecycle before closing stdin; the client does
not close it automatically. The single-turn examples close after their first
result and do not manage background tasks.

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
- `control_response` lines are matched to accepted requests. Sixteen pending
  slots are shared by initialization and interrupts: at most fifteen interrupts
  while initialization is pending, sixteen otherwise. Overflow returns
  `error.TooManyPendingRequests`; accepted initialization is never evicted.
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
- Public writes distinguish closed stdin, write failure, deadline expiration,
  terminal transport, and a full pending-interrupt list. A partial write or
  deadline failure disables further writes; start a new session after cleanup.
- The control channel is pumped only while the caller is inside `next()`. That
  is fine for a turn-driven loop, since the caller is always there while the
  agent is working. A host that wants tool calls serviced while it does other
  work keeps one thread in `next` and drives the rest from others.
- Client methods synchronize stdin writes, event reading, and lifecycle state.
  Keep a single `next()` consumer; handlers must not call its non-reentrant
  read loop. `close()` destroys the client and must follow every other call
  and every thread join. Handlers may call send methods or termination APIs.
- `lastLine()` belongs to the `next()` consumer until its next call.
  `lastControlError()` belongs to that consumer until the next rejection or
  `close()`. `sessionId()` is synchronized.
  `status()` returns a synchronized snapshot of initialization, termination,
  reap, stdin, and transport state. Read status through this method while
  other threads run; direct access to mutable public fields is not synchronized.
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

macOS on Apple Silicon is the supported and validated target. The local gate
and runtime stress tests run natively on macOS. Linux is untested and is
outside the supported-platform validation scope.

The transport uses POSIX pipe and signal operations. Integration tests and
benchmarks also require `/bin/sh`. Windows is not supported.

## Build

```
zig build
zig build test
CLAUDE_BIN=claude zig build run -- "explain this repo"
zig build examples-check     # compile complete lifecycle examples
zig build bench -Doptimize=ReleaseFast -- 20000 all 5
zig build docs               # autodocs for the agent module into zig-out/docs/
```

`build.zig` refuses any Zig other than the one `build.zig.zon` names
(`0.17.0`): the manifest's `minimum_zig_version` is only a floor, and a later
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
just ci-extended                  # supervised macOS checks, examples, ReleaseFast, docs
just canary-strict                # fail if CLI compatibility cannot be checked
just ci-full                      # extended gate plus strict CLI parser probes
just runtime-validate _dev/validation/macos # fresh tests, 100 stress runs/group, generated fuzz
just compatibility-live _dev/validation/live # opt-in model calls with sanitized evidence
just bench [lines] [workload] [runs] # real-pipe benchmark, ReleaseFast
just docs                         # autodocs into zig-out/docs/
just release <version>            # dist/: tarball, SHA256SUMS, SBOM, optional signature
just release-verify <version>     # check dist/ sums, and the signature when configured
just canary-schedule-install      # run the canary weekly (launchd on macOS)
just canary-schedule-uninstall    # remove that schedule
```

Benchmark workloads are `normal`, `escaped`, `large` (8 KiB deltas),
`control` (one dispatched MCP tool call per delta), and `recovery` (one
2 MiB event followed by normal deltas); `all` runs each. Output is JSONL,
one record per repetition. Startup and transcript generation are excluded;
latency includes `next()`, accessor work, and owned-event cleanup. Retained
SDK memory is measured after EOF and before `close`; harness transcript and
latency-array memory are excluded. The recovery workload checks that a large
valid event does not pin its buffers for subsequent small events.

Use at least five release runs with the same machine, compiler, and workload.
Compare medians and dispersion; investigate repeatable throughput regressions
above 10% or allocated-bytes/event increases above 10%. These are investigation
triggers, not hardware-independent performance guarantees. A small extended-gate
run checks execution and cleanup only; it is not a performance baseline.

`scripts/bench_compare.py` compares explicitly supplied before/after executables
in seeded, balanced pairs, excluding warmups. It records build/source hashes,
host load, raw metrics, and paired uncertainty estimates in a new ignored
directory. Compile both executables with the same harness, Zig, mode, and
target; the collector rejects mismatched metadata or changing inputs.

The tooling files, none of which are part of the package:

| File | |
|---|---|
| `build.zig` | Library, demo, tests, complete examples, benchmark, docs, and exact toolchain guard. |
| `justfile` | Every recipe above. |
| `bench/next_bench.zig` | Five real-pipe workloads with latency distributions, throughput, allocation, and memory metrics. |
| `scripts/docs-check.sh` | The README-vs-tree gate: the Layout table must match `src/`, `examples/`, `tests/` exactly, and the Usage block must compile. |
| `scripts/release.sh` | Cuts `dist/` for a version; never tags, commits, or pushes. |
| `scripts/release-verify.sh` | Checks what `release.sh` left in `dist/`. |
| `scripts/runtime_validation.py` | Fresh native test counts, stress/fuzz campaigns, and source fingerprints. |
| `scripts/live-compatibility.py` | Explicitly authorized live protocol matrix with sanitized evidence and owned-session cleanup. |
| `scripts/bench_compare.py` | Supervised, seeded paired performance comparisons. |
| `.githooks/pre-commit` | `fmt-check` and `docs-check` on the working tree. |
| `.githooks/pre-push` | `just ci` on each distinct pushed ref tip, in a temporary worktree. |

**CI is strictly local, by design: there is no hosted CI and no workflow file.**
The gate is two git hooks under `.githooks/`, version-controlled rather than
hidden in `.git/hooks/`, and installed once per clone with `just hooks-install`
(which points `core.hooksPath` at the directory). `pre-commit` runs the fast
checks, formatting and the README drift check, on the working tree.
`pre-push` gates each distinct pushed ref tip in a temporary detached
worktree, using that tip's own `justfile`. It does not test every intermediate
commit in a pushed range. Both hooks can be bypassed with `--no-verify`;
there is no remote enforcement. `just ci-extended` adds supervised runtime
checks, complete-example compilation, ReleaseFast tests, docs generation,
offline compatibility fixtures and tooling tests on macOS.
`just runtime-validate PATH` additionally compiles and directly executes every
test root in Debug, ReleaseSafe, and ReleaseFast, repeats each race group 100
times, and runs both fuzz harnesses. Its new, ignored output directory records
the source fingerprints, host/toolchain, exact commands, and actual test counts;
cached summaries cannot pass as fresh executions.
`just canary` probes the installed CLI parser and may skip a missing binary;
`just canary-strict` fails when compatibility cannot be checked. Neither
submits model requests. `just compatibility-live PATH` separately opts into
seven real CLI scenarios: MCP registration/list/call, permission allow/deny/
replacement, interruption, correlated rejection, and persisted-session resume.
The rejection scenario explicitly changes one interrupt subtype to an invalid
value to exercise a real CLI refusal. The matrix uses harmless SDK tools,
temporary workspaces, at most eight CLI clients, USD 0.05 per-client budget
thresholds, and a 60-second deadline per scenario. Budget thresholds are not
billing guarantees. Sanitized wire evidence and generated-session cleanup are
recorded in a new evidence directory. Live model use is never part of a gate.

Releases are cut locally too. `just release <version>` refuses a dirty tree, a
version that does not match `build.zig.zon`, or a version `CHANGELOG.md` has no
heading for; runs the extended gate and strict CLI probes; and writes `dist/`: a `git archive` tarball,
a minimal CycloneDX 1.5 SBOM, `SHA256SUMS` over both, and an `ssh-keygen`
signature of the sums when `RELEASE_SIGNING_KEY` names a key. It prints the
`git tag` command and stops; tagging and pushing the tag stay the owner's
decision. `just release-verify <version>` checks the sums and, when
`RELEASE_ALLOWED_SIGNERS` is set, the signature. It validates every archive
entry and structured SBOM metadata, then builds an extracted package consumer.
Without a signer trust file, checksum success does not authenticate provenance.

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
