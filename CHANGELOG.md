# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project documentation: `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, and this
  changelog.
- `tests/`, a black-box suite that reaches the library only through its public
  surface: `tests/all.zig` as the root, with `client_test.zig`, `event_test.zig`,
  `options_test.zig`, and `tool_test.zig` beside it. Tests that drive private
  internals stay in their own module, each noting the symbol that keeps it
  there.
- A pre-push hook in `.githooks/`, and a `justfile` task runner covering build,
  test, format, and CI.

### Changed

- The tree is split by role: `src/` is the library alone, `examples/` holds the
  demo, and `tests/` holds the black-box suite. `src/main.zig` moved to
  `examples/demo.zig` and the demo's tools to `examples/demo_tools.zig`.
  Everything outside `src/` now reaches the library through a module named
  `agent` rather than by relative path, since a Zig file belongs to exactly one
  module and a root outside `src/` cannot import upward.
- The reported test count fell from 62 to 39 without losing coverage: the demo
  root used to import the library by relative path, so the library suite
  compiled into two roots and ran twice.
- Hardening across the client: an explicit `WriteError` on the write path
  instead of one inferred through `std.json.Stringify`, `StdinClosed` returned
  for a send after `closeStdin` rather than an assert that vanishes in
  `ReleaseFast`, `OutOfMemory` propagated instead of being flattened into tool
  text or `WriteFailed`, and an oversized protocol line resynced to the next
  newline rather than wedging the stream. Control dispatch answers every
  malformed request it can address.
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

### Fixed

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

<!-- Both links resolve once `v0.1.0` is tagged and pushed. -->

[Unreleased]: https://github.com/cipher-rc5/claude_zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cipher-rc5/claude_zig/releases/tag/v0.1.0
