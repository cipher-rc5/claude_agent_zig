# claude_agent_zig technical documentation

This directory explains how `claude_agent_zig` works internally and what its
wire protocol looks like. The top-level [README](../README.md) is still the
user guide and the source of truth for the API contract. These pages go
further into structure, control flow and message shapes, with Mermaid
diagrams.

The library is a Zig 0.17.1 client for the Claude Code CLI. It spawns
`claude --print --input-format stream-json --output-format stream-json --verbose`
as a child process and runs a bidirectional, newline-delimited JSON protocol
over the child's stdin and stdout pipes. It depends on nothing beyond the
standard library.

## Contents

| Document | Covers |
|---|---|
| [architecture.md](architecture.md) | Module graph, layering, build graph, trust boundaries. |
| [api-reference.md](api-reference.md) | Public types re-exported by `src/agent.zig`, every `Options` field, error sets, limits. |
| [client-lifecycle.md](client-lifecycle.md) | `open`, initialization handshake, `wait`/`terminate`/`forceKill`/`close`, state machines. |
| [read-loop.md](read-loop.md) | Owned `next()` and borrowed `nextView()`: framing, validation, lifetimes and error recovery. |
| [control-protocol.md](control-protocol.md) | Control request dispatch: in-process MCP tools, permission prompts, request correlation. |
| [wire-protocol.md](wire-protocol.md) | JSON schema of every message the client reads or writes, with examples. |
| [concurrency.md](concurrency.md) | Mutexes, lock order, atomics, which calls are safe from which thread. |
| [transport.md](transport.md) | Nonblocking pipe reader and writer, write deadlines, child reaping. |
| [tooling.md](tooling.md) | Build steps, test roots, local gates, compatibility checks, release pipeline. |

## Source map

| File | Role | Documented in |
|---|---|---|
| `src/agent.zig` | Public surface; re-exports everything callers use. | [api-reference.md](api-reference.md) |
| `src/options.zig` | `Options`, `PermissionMode`, `buildArgv`. | [api-reference.md](api-reference.md), [client-lifecycle.md](client-lifecycle.md) |
| `src/event.zig` | `Event`, `EventView`, `Kind`, parsing and field accessors. | [read-loop.md](read-loop.md) |
| `src/tool.zig` | `Tool`, `McpServer`, handler and decision types. | [control-protocol.md](control-protocol.md) |
| `src/protocol.zig` | Serializers for every outbound line. | [wire-protocol.md](wire-protocol.md) |
| `src/client.zig` | Process lifecycle, read loop, control dispatch. | [client-lifecycle.md](client-lifecycle.md), [read-loop.md](read-loop.md), [control-protocol.md](control-protocol.md) |
| `src/transport.zig` | Nonblocking POSIX pipe I/O with deadlines; `waitpid` polling. | [transport.md](transport.md) |

## Keeping these pages accurate

`just docs-check` checks only the top-level README, not this directory. When
you change a constant, an error set, a wire shape or the lock order, update
the page that covers it. The constants quoted here come from:

| Constant | Value | Defined in |
|---|---|---|
| `max_tool_result_bytes` | 16 384 | `src/client.zig` |
| `max_reply_line_bytes` | 16 896 (16 384 + 512 envelope) | `src/client.zig` |
| `max_pending_requests` | 16 | `src/client.zig` |
| `retain_bytes` (buffer retention cap) | 1 MiB | `src/client.zig` |
| JSON nesting limit | 128 containers | `jsonDepthWithin` in `src/client.zig` |
| `default_protocol_version` | `2025-11-25` | `src/protocol.zig` |
| `modern_protocol_version` | `2026-07-28` | `src/protocol.zig` |
| `supported_protocol_versions` | `2026-07-28`, `2025-11-25`, `2025-06-18` | `src/protocol.zig` |
| `list_cache_ttl_ms` / `list_cache_scope` | `0` / `private` | `src/protocol.zig` |
| `min_cli_version` | `2.1.228` | `src/options.zig` |
