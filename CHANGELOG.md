# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Project documentation: `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, and this
  changelog.

### Changed

- Hardening and robustness work across the client is in progress. Details will
  be recorded here as the individual changes land.

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

<!-- No release tag has been cut yet, so these two links resolve only once
     `v0.1.0` is tagged and pushed. -->

[Unreleased]: https://github.com/cipher-rc5/claude_zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cipher-rc5/claude_zig/releases/tag/v0.1.0
