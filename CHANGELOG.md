# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Host permission callbacks with allow, replacement-input, and deny decisions.
- `Client.status()` and `InitializationState` for synchronized lifecycle and
  handshake state. `InitializationRejected` distinguishes handshake rejection
  from interrupt rejection; `lastControlError()` retains the CLI diagnostic.
- `Client.terminate(grace_ms)` and `forceKill()` with one coordinated reaper,
  SIGTERM-to-SIGKILL escalation, and cancellation of blocked pipe I/O.
- Pipe-I/O deadlines after acquiring the write lock through
  `Options.write_timeout_ms`, including the initialization write. `termination_grace_ms` configures `kill()` escalation.
- Complete executable streaming, permissions, initialization-rejection, and
  shutdown examples, compiled by `zig build examples-check`.
- Five real-pipe benchmark workloads with repeated JSONL output, latency
  percentiles, allocation costs, and peak/retained SDK-owned memory.
- API documentation generation, allocation-failure and protocol fuzz tests,
  and concurrent real-pipe regression coverage.
- Supervised extended local checks, ReleaseFast tests, offline synthetic
  protocol compatibility fixtures, and strict CLI parser checks for releases.
- Fresh macOS runtime evidence with bounded concurrency stress and generated
  fuzzing; seeded paired benchmark comparisons with build/source fingerprints.
- An opt-in live CLI matrix for MCP, permission decisions, interruption,
  correlated rejection, and resumed sessions, with sanitized evidence and cleanup.
- Local source archives, structured CycloneDX SBOMs, checksums, optional SSH
  signatures, and artifact verification with an isolated package consumer.

### Changed

- Platform support and required validation now target macOS on Apple Silicon;
  Linux remains untested and is no longer part of the required gate.
- Requires Zig 0.17.0 exactly; updated argument forwarding, array syntax, and
  reflection assertions for that toolchain.
- Client methods synchronize reads, writes, and lifecycle state. Keep one
  `next()` consumer and join all client-using threads before `close()`.
- `kill()` now escalates after the configured grace interval. `wait()` and
  `close()` retain their unbounded graceful-wait behavior.
- Failed, partial, or timed-out writes disable the transport. Public errors
  include `WriteTimedOut`, `TransportFailed`, `TooManyPendingRequests`, and
  terminal `ReplyTooLong`; callers should terminate and start a new session.
- Pending interrupts are bounded explicitly; overflow is rejected instead of
  evicting accepted requests. Initialization shares the sixteen-slot pending
  capacity and cannot be evicted by interrupts.
- Local hooks validate the working tree before commits and each distinct
  pushed ref tip before pushes. Intermediate pushed commits are not checked.
  CI remains local and can be bypassed; there is no remote enforcement.
- Release validation fails when CLI compatibility cannot be checked.
  Verification checks every archive entry, exact source membership, structured
  metadata, and checksums. Signer trust remains explicitly configurable.
- Library, examples, and public tests use separate module roots. Line and
  scratch buffers retain at most 1 MiB each after their next reuse.

### Fixed

- Every control reply, denial, and fallback obeys the complete rendered-frame
  budget, including escaped bytes, ids, and newline. Unrepresentable
  correlation metadata ends the session without truncating ids.
- Blocked stdin, ignored SIGTERM, startup backpressure, concurrent waits, and
  inherited stdout descriptors no longer prevent the supported termination
  path from progressing. Only the direct child is signaled; synchronous host
  handlers still require cooperation.
- Child signaling and reap publication use shared coordination to avoid
  signaling a reused pid. Reaping does not close a reader's live descriptor.
- Control acknowledgements require the exact emitted request ID; signed or
  zero-padded numeric suffixes cannot acknowledge another request.
- Initialize and interrupt requests put correlation IDs in the top-level
  control envelope so real CLI acknowledgements match pending requests.
- Lifecycle guidance covers canceled turns and tool calls from background
  tasks after a foreground result; single-turn examples state their scope.
- Local command supervisors clean up their process groups even if the driver
  is killed; interrupted validation retains partial evidence without success.
- Empty/duplicate registration names, malformed schema objects, invalid
  buffers, and zero write deadlines fail before the session starts.
- JSON nesting above 128 returns terminal `ProtocolTooDeep`; deep schemas
  fail validation and deep replacement permission input is denied.
- Malformed/oversized input resynchronizes at a newline; boundary-sized lines
  are accepted. Closed stdin fails explicitly rather than using a recycled fd.
- Demo environment reads use an explicit non-secret allowlist. Demo arithmetic
  preserves exact i64 operands and rejects overflow and non-decimal input.
- The demo inherits an unset skill allowlist correctly. Oversized MCP replies
  preserve method-appropriate error shapes.

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
