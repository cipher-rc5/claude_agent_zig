# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project documentation: `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, and this
  changelog.
- Fuzz harnesses (`src/client.zig`, under `// --- fuzz ---`): `readLine` over
  arbitrary bytes with an arbitrary `max_line_bytes`, bounded so a resync
  regression fails instead of hanging, and `serveControlRequest` over
  arbitrary JSON, pinning that it answers with exactly one terminated line or
  stays silent only when there is no id. A plain `zig build test` runs the
  corpus and the empty input; `zig build test --fuzz` runs them for real.
- `tests/`, a black-box suite that reaches the library only through its public
  surface: `tests/all.zig` as the root, with `client_test.zig`, `event_test.zig`,
  `integration_test.zig`, `options_test.zig`, and `tool_test.zig` beside it.
  `integration_test.zig` drives the real client over actual pipes against
  `#!/bin/sh` stub CLIs written at runtime: lifecycle, tool calls, framing,
  and the deadlock regression under a deadline. Tests that drive private
  internals stay in their own module, each noting the symbol that keeps it
  there.
- Permission prompts (`src/tool.zig`, `src/options.zig`, `src/protocol.zig`,
  `src/client.zig`). `Options.permission_handler` and `permission_context`
  install a `PermissionHandler`, a function of `(context, arena, tool_name,
  input)` returning a `PermissionDecision` of `.allow`,
  `.allow_with_input = "<json object>"`, or `.deny = "<message>"`. When a
  handler is set `buildArgv` appends `--permission-prompt-tool stdio`, which
  is what makes the CLI emit prompts as control requests (measured against
  2.1.261: `--permission-prompts host` on its own emits none and the call is
  blocked), plus `--permission-prompts host`, which the CLI's help names as the
  SDK-host route; a handler also makes `needsInitialize` true, since the CLI
  routes prompts to a host that opened with the handshake. Each prompt arrives as a
  `can_use_tool` control request that `next()` answers on the caller's thread:
  `{"behavior":"allow","updatedInput":<input>}` for an allow (the proposed
  input echoed, or the handler's object spliced raw after validation — a
  non-object becomes a deny rather than a corrupted frame), or
  `{"behavior":"deny","message":"..."}`. A handler error is answered as a deny
  carrying its name; `OutOfMemory` is answered as a deny and then propagated;
  a request without `tool_name` gets a control error; absent input reaches the
  handler as JSON `null`. The reply is bounded like a tool result because it
  carries the CLI-sized input back, so an allow whose line exceeds 16 896
  bytes is turned into a deny naming the size and the bound. Without a
  handler, `can_use_tool` gets the `unsupported control request` reply it
  always did. Exercised against scripted stub CLIs over real pipes, and once
  end to end against CLI 2.1.261: with `permission_mode = .manual` and
  `tools = "Bash"`, a `mkdir` the model was asked to run arrived as one
  `can_use_tool` request, the handler's allow was honoured, and the directory
  existed afterwards. A bare `echo` never prompts (the CLI treats it as
  read-only) and a settings source with `permissions.defaultMode: auto`
  settles the call first, so neither exercises the handler. The demo installs
  a log-and-allow handler (`examples/demo_tools.zig`) when
  `AGENT_PERMISSIONS=host` is set.
- `Client.lastLine()` (`src/client.zig`): the raw bytes of the most recent
  protocol line, whether it became an event, failed to parse behind
  `error.InvalidJson`, or was the prefix that fit before
  `error.ProtocolTooLong`. A host can now log what the CLI actually sent.
  Valid until the next call to `next()`.
- `Client.lastControlError()` and `ReadError.ControlRequestRejected`
  (`src/client.zig`). `control_response` lines used to be discarded unread,
  so the CLI refusing this client's own `initialize` — an `sdkMcpServers`
  entry it would not take — was indistinguishable from success, and the first
  symptom was the model reporting it could not find a tool. The ids this
  client mints are now kept in a fixed 16-slot pending list and matched on the
  way back; an `error` subtype for one of them is returned from `next()` with
  the CLI's text in `lastControlError()`. The stream stays readable.
- `OpenError.InvalidToolSchema` (`src/client.zig`, `src/tool.zig`). Every
  `Tool.input_schema` is spliced into the `tools/list` reply verbatim, so
  `open` now checks that each parses as JSON and is an object before it
  allocates or spawns anything, rather than letting a malformed one corrupt the
  frame mid-session.
- `agent.min_cli_version` (`src/options.zig`), `"2.1.228"`: the oldest CLI
  this protocol has been exercised against. Not probed at `open`, since that
  would cost a spawn per session; `just canary` parses it out of the source
  and fails when the installed CLI is below it, or when the declaration cannot
  be found.
- Dispatch-level tests for the MCP handshake in `src/client.zig`: `initialize`
  echoing the offered `protocolVersion` and falling back to the default,
  `notifications/initialized` answered under id 0, and a successful
  `tools/list`; plus `buildArgv` tests pinning the default argv exactly, every
  flag-emitting field, and that `extra_args` is exactly the tail of the argv.
- A concurrency test (`tests/integration_test.zig`) driving two clients from
  two threads at once, each against its own stub CLI with its own session id
  and its own `sdk_mcp_servers` tool. `Client` is single-threaded per
  instance, but nothing in `src/` is global, so independent clients are
  expected to run side by side; that was true by construction and untested
  until now. The test pins both the session ids and the tool replies, so
  hoisting any per-client state to a global fails here rather than in a host.

- A `pre-commit` hook in `.githooks/` running `fmt-check` and `docs-check` on
  the working tree, beside the existing `pre-push`; both installed by
  `just hooks-install`.
- `just test-release` (`zig build test -Doptimize=ReleaseSafe`), now part of
  `ci`: the client reasons about release modes explicitly — asserts that
  vanish under `ReleaseFast`, safety checks that stay under `ReleaseSafe` —
  so the gate runs the suite under one of them rather than Debug alone.
- A local release pipeline: `just release <version>` (`scripts/release.sh`)
  refuses a dirty tree, a version that differs from `build.zig.zon`, or one
  this file has no heading for; runs `just ci-full`; and writes `dist/` with a
  `git archive` tarball, a minimal CycloneDX 1.5 SBOM, `SHA256SUMS` over both,
  and an `ssh-keygen` signature of the sums when `RELEASE_SIGNING_KEY` is
  set. It prints the `git tag` command and never tags, commits, or pushes.
  `just release-verify <version>` (`scripts/release-verify.sh`) checks the
  sums, the archive prefix, the SBOM, and — only when
  `RELEASE_ALLOWED_SIGNERS` is set — the signature, reporting it as not
  checked otherwise. `dist/` is git-ignored.
- `just canary-schedule-install` and `canary-schedule-uninstall`: a launchd
  agent on macOS that runs the canary every Monday at 09:00 and logs to
  `~/Library/Logs/claude_agent_zig-canary.log`; on other systems the recipe
  prints the crontab line to add. The canary only catches drift if something
  runs it.
- `zig build bench` / `just bench [lines]` (`bench/next_bench.zig`): streams
  a synthetic `stream_event` transcript through `next()` over a real pipe and
  reports events/s, bytes and allocator calls per event, and peak live bytes,
  so the per-event `alloc_always` tree parse has a measured cost and a
  baseline. Measured on Apple Silicon with zig 0.16.0: 20 000 deltas under
  ReleaseFast run at 98k–134k events/s (7.5–10.3 µs/event, a figure that
  includes stub start-up), and 100 000 deltas at 357k events/s (2.8 µs/event),
  at 5 601 bytes and 6.0 allocator calls per event with about 89 KB peak
  live; ReleaseSafe is 107k events/s at the same bytes and calls.
- `zig build docs` / `just docs`: autodocs for the `agent` module into
  `zig-out/docs/`.
- `build.zig` refuses any Zig version other than the one `build.zig.zon`
  names, at comptime with a message naming both. The manifest's
  `minimum_zig_version` is a floor, so a later toolchain was accepted there and
  failed inside `std` instead.

### Changed

- `Client` is thread safe. Any method may be called from any thread,
  concurrently with any other, under two rules: `next` is single-consumer, and
  a handler must not call it from inside `next`; `close` must be the last call.
  Three `Io.Mutex` locks back this, one per concern. The write lock covers the
  stdin writer, `stdin_closed`, `flush_error`, and the `zig_N` request list,
  and is held for one whole line and its flush by `send`, `sendCommand`,
  `interrupt`, `closeStdin`, and every control reply `next` writes, so two
  writers can no longer interleave a line on the pipe. It is not held while a
  tool or permission handler runs, so a handler may `send`. The read lock is
  held across `next`; `close` takes it after the reap so it cannot free the
  client under a reader. The state lock and a condition cover `term`,
  `killed`, `wait_error`, `stdout_closed`, `session_id`, and a `waiting` flag
  that marks the one thread inside the blocking reap: a second `wait` or
  `close` sleeps on the condition and returns the same status instead of
  reaping twice. `sessionId` now takes `*Client`, since it reads under the
  state lock; `lastLine` and `lastControlError` belong to the thread that
  called `next`. The README's "not thread safe" note, the watchdog warning,
  and `SECURITY.md`'s reliance on the single-thread rule are rewritten to the
  new contract, and `tests/integration_test.zig` drives the client from real
  OS threads: eight senders against a reader, a watchdog `kill` against a
  parked `wait`, a `kill` against a reader blocked in `next`, and two
  concurrent `wait`s.
- `kill` from a watchdog thread is sound, and `term` after it is observed
  rather than synthesized. When another thread is inside the reap, `kill`
  sends `SIGTERM` by pid — captured at spawn as `Client.pid` — and lets that
  thread observe the death; otherwise it signals and reaps itself through the
  ordinary `Child.wait`. Either way there is exactly one reap, and `term` is
  what the kernel reported: a child that traps the signal and exits cleanly is
  `killed` with an `.exited` term. This removes the README's "no way to bound
  `close`" limitation; the deadline still has to come from another thread,
  since Zig 0.16's `Io` exposes no timed child wait. `kill` after a failed
  reap now returns without signalling once the stdlib has cleared the handle,
  since the pid may already have been reissued.
- `open` moves the child's stdout descriptor out of the `Child` and the
  client owns it until `close`. The stdlib closes every descriptor a `Child`
  still holds when it reaps, which was the stale-fd hazard `stdout_closed`
  guarded against on one thread and would have been a live one under a
  reader blocked in `next` on another. The reap no longer touches the
  descriptor; a reader parked in `read` sees end of stream when the child
  dies. `stdout_closed` stays, so `next` after a reap still reports end of
  stream rather than handing out whatever the child left buffered.

- The tree is split by role: `src/` is the library alone, `examples/` holds the
  demo, and `tests/` holds the black-box suite. `src/main.zig` moved to
  `examples/demo.zig` and the demo's tools to `examples/demo_tools.zig`.
  Everything outside `src/` now reaches the library through a module named
  `agent` rather than by relative path, since a Zig file belongs to exactly one
  module and a root outside `src/` cannot import upward.
- The reported test count stopped double-counting. The demo root used to import
  the library by relative path, so the library suite compiled into two roots and
  ran twice; the count `zig build test` printed was inflated rather than the
  coverage being larger. Each test now runs exactly once, summed across the
  three roots — `src/agent.zig`, `tests/all.zig`, and `examples/demo.zig`. No
  count is quoted here because it moves with every test added; run
  `zig build test --summary all` for the current figure and its per-root split.
- Hardening across the client: an explicit `WriteError` on the write path
  instead of one inferred through `std.json.Stringify`, `StdinClosed` returned
  for a send after `closeStdin` rather than an assert that vanishes in
  `ReleaseFast`, `OutOfMemory` propagated instead of being flattened into tool
  text or `WriteFailed`, and an oversized protocol line resynced to the next
  newline rather than wedging the stream. Control dispatch answers every
  malformed request it can address.
- `WriteError` is now exactly `error{ StdinClosed, WriteFailed }`
  (`src/client.zig`). It carried `Allocator.Error` although no write path
  allocates — `send` and `interrupt` render straight into the stdin writer's
  buffer and `sendCommand` streams its text in escaped pieces — so the public
  set was wider than the behaviour.
- The pipe-safety bound is measured on the whole rendered `control_response`
  line, envelope, ids and newline included, since that is what lands in the
  pipe; the headroom over `max_tool_result_bytes` went from 256 to 512 bytes
  to cover CLI-sized request ids, so the enforced line bound is 16 896 bytes
  (`src/client.zig`). `max_tool_result_bytes` is unchanged at 16 384 and its
  doc comment, which said the envelope was bounded separately, now says what
  is measured.
- `Client.reply_override`, the test seam that redirects protocol replies, is
  `void` outside test builds (`if (builtin.is_test)`), so it no longer exists
  as a settable field on the public struct (`src/client.zig`).
- The argv arena is freed as soon as `spawn` returns instead of living for the
  client's lifetime; the child retains no reference to it (`src/client.zig`).
- The line buffer and the scratch arena keep their capacity up to 1 MiB and
  release it past that, so one event near `max_line_bytes` no longer pins its
  size for the session; the usual small line still costs no allocation
  (`src/client.zig`).
- `Kind` stays exhaustive, now with the reason documented: `unknown` already
  absorbs every wire type the enum does not name, so a non-exhaustive `_` tag
  would never be produced. Adding a variant is a source-breaking change for a
  `switch (e.kind)` that names every arm; write an `else` arm
  (`src/event.zig`).
- Added `wait()`, `sessionId()`, and a `kill()` escape hatch; `close()` keeps
  its signature and delegates. A CLI that dies on startup is now reported
  through its exit status rather than read as an empty but successful run.
- The demo `add` tool stays exact past 2^53. A JSON `number` is an IEEE 754
  double by the time it reaches the wire — measured against the CLI,
  `{"type":"integer"}` rounds identically — so the operands are declared as
  decimal strings, which is the only shape that survives the round trip. The
  handler now also honours that schema in the other direction: an integer too
  large for `i64` is reported rather than silently answered as a float, mixed
  integer and fractional operands no longer discard the integer's exactness,
  and non-decimal or non-finite inputs are rejected instead of producing a
  confident wrong answer.
- The README's in-process tool example shows the string schema the reasoning
  above calls for, with a note on why.
- `just ci` is now `fmt-check`, `docs-check`, `test`, `test-release`, `build`,
  and `fmt`/`fmt-check` cover `bench/` alongside `build.zig`, `src`,
  `examples`, and `tests`. The `pre-push` hook no longer validates the working
  tree with a warning when it diverges from the pushed commit: it checks each
  pushed commit out into a temporary detached worktree, runs `just ci` there
  with that commit's own `justfile` (sharing the main tree's `.zig-cache` so
  the two optimize modes are incremental), and removes the worktree on every
  exit path. A sha that cannot be checked out blocks the push; a ref delete is
  skipped with a note. `just canary` now probes `--permission-prompts`,
  probes `--permission-prompt-tool` by rejection (it is absent from `--help`,
  like `--max-turns`), and enforces the CLI version floor.

### Fixed

- The demo's `host_env` tool handed the model any inherited environment
  variable it asked for. Its argument is model-influenced, the process
  inherits its parent's environment — which on a developer machine routinely
  holds cloud and API credentials — and the demo pre-authorizes
  `mcp__host__*`, so an injected turn could read a secret straight out of it.
  It now answers only for a fixed non-secret allowlist (`HOME`, `LANG`,
  `PATH`, `PWD`, `SHELL`, `TERM`, `USER`), enumerated in both the schema and
  the handler, with the refusal issued before the lookup so the reply cannot
  distinguish a set secret from an unset one (`examples/demo_tools.zig`).
- The `justfile` exported `AGENT_SKILLS` through `env_var_or_default(..., "")`,
  which set it to the empty string on every run. The demo reads an empty
  `AGENT_SKILLS` as a deliberate empty allowlist, so `just dev` silently
  disabled every skill — the documented default inverted. The export is gone
  and the caller's environment passes straight through.
- An oversized `initialize` or `tools/list` reply was replaced with a
  `toolCall`-shaped body, which is malformed for those methods: past roughly
  seventeen tools with 1 KiB schemas the CLI received `{"content":[...],
  "isError":true}` where it expected `{"tools":[...]}`, the server's tools
  silently failed to register, and the model reported it could not find them.
  Those methods now get a JSON-RPC `-32603` error naming the line size and the
  bound; `tools/call` keeps the `is_error` replacement (`src/client.zig`).
- A tool result larger than the stdin pipe buffer used to wedge the client and
  the CLI permanently: the reply is written from inside `next()`, so it blocked
  there while the child blocked writing stdout that nothing was draining, with
  `kill` unreachable from the caller's own thread. Handler text is now capped
  at `agent.max_tool_result_bytes` (16 KiB) and an over-long result is reported
  to the model as a failed call. Zig 0.16 exposes no readiness or non-blocking
  primitive for a child pipe, so a ceiling below the smallest plausible pipe
  buffer is the available fix rather than interleaved reads.
- `next()` could return events parsed from an unrelated file after the child
  was reaped. `Io.File.Reader` holds its `File` by value, so `wait()` and
  `kill()` left the reader holding a descriptor the stdlib had already closed;
  once the OS reused that number, the read loop parsed whatever now owned it.
  A `stdout_closed` guard mirrors the existing `stdin_closed` one, and `next()`
  now reports a clean end of stream instead — which also means `next()` after
  `wait()` returns `null` rather than `error.ReadFailed`.
- A handler returning `error.OutOfMemory` left the CLI waiting out its own
  timeout; the client now answers `-32603` before propagating.
- A numeric `request_id` on a control request went unanswered, because only a
  string id was read. Numeric ids are now rendered and replied to; only a
  genuinely absent id is unanswerable.
- A protocol line of exactly `max_line_bytes` was rejected, though the field
  documents the limit as inclusive. `max_line_bytes = 0` is now rejected at
  `open()` with `error.InvalidMaxLineBytes` rather than failing every read.
- `kill()` records `killed` alongside `term`, so the synthesized
  `.signal = TERM` is distinguishable from an observed exit status.
- The test "a failed reap is cached but does not disarm kill" only read back a
  field it had set itself; it is dropped in favour of the live-child variant,
  which observes `kill` running after a failed reap against a real child.

### Notes

- Further hardening is in progress; individual changes are recorded here as
  they land.

## [0.1.0] - 2026-08-22

Initial implementation.

### Added

- `Client` (`src/client.zig`): spawns the Claude Code CLI as a child process
  with `--print --input-format stream-json --output-format stream-json
  --verbose`, and drives the resulting bidirectional newline-delimited JSON
  protocol over its stdin/stdout pipes. Handles process lifecycle, the read
  loop, and control-request dispatch. Heap allocated so the embedded reader and
  writer interfaces keep a stable address.
- `Options` and `PermissionMode` (`src/options.zig`): session configuration and
  the CLI flags it translates into, covering model selection, `allowed_tools`,
  permission modes, `bare` sessions, `max_turns`, session resumption, buffer
  sizing, and an `extra_args` escape hatch.
- Skill discovery and scoping through `setting_sources`, `add_dirs`, and
  `plugin_dirs`, plus a `skills` invocation allowlist sent on the `initialize`
  control request. `null` allows every discovered skill and an empty slice
  allows none.
- `Event` and `Kind` (`src/event.zig`): one protocol line and the typed
  accessors for reading it. Events are parsed to `std.json.Value` rather than
  fixed structs, so a new field in a CLI release does not break parsing.
- In-process MCP tools (`src/tool.zig`): `Tool`, `ToolResult`, `McpServer`, and
  the `ToolHandler` signature. Tools run as Zig functions in the host process,
  reached over the same control channel, with no subprocess or socket involved.
  Claude addresses them as `mcp__<server>__<tool>`.
- Wire protocol writers (`src/protocol.zig`): the `initialize`, `tools/list`,
  and `tools/call` MCP results, JSON-RPC error replies, and control-request
  responses. Unsupported control requests get an explicit error response rather
  than silence, so the CLI does not stall until its own timeout.
- Line reading via `streamDelimiterLimit` into an `Io.Writer.Allocating`, so a
  single event larger than the read buffer is handled without a fixed cap,
  bounded by `max_line_bytes`.
- `src/agent.zig` as the single public surface, re-exporting the types above.
- Demo client (`src/main.zig`) streaming one turn to stdout, with two example
  tools in `src/demo_tools.zig`.
- `justfile` task runner: `build`, `test`, `check`, `fmt`, `fmt-check`, `ci`,
  `dev`, `dev-release`, `clean`, and `versions`.
- Unit tests across the modules, run from the `src/agent.zig` and `src/main.zig`
  roots.

### Notes

- Requires Zig 0.16.0. No dependencies beyond the standard library.
- The `claude` CLI must be installed and on `PATH`, or named explicitly via
  `claude_path`.
- Permission callbacks are not implemented; pre-authorize with `allowed_tools`
  or a permission mode.

<!--
Version links are deliberately absent. No tag exists yet (`git tag -l` is
empty), so a compare or release URL for `v0.1.0` would 404. Add them here once
the tag is pushed:

    [Unreleased]: .../compare/v0.1.0...HEAD
    [0.1.0]:      .../releases/tag/v0.1.0
-->
