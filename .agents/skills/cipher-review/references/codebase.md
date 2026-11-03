# SDK codebase map

Navigation for `claude_agent_zig`; verify declarations and constants against the current checkout. Source and `CONTRIBUTING.md` govern when this map drifts.

## Architecture and tooling

The library spawns Claude Code CLI with `--print --input-format stream-json --output-format stream-json --verbose` and exchanges NDJSON over pipes. It implements no model loop, database, HTTP server, or direct network client. In-process MCP tools use the same control channel.

The package uses only Zig's standard library. `build.zig.zon` pins Zig 0.17.0 and `build.zig` enforces exact equality. Python 3.12+, shell, `just`, Git, and SSH support delivery tooling. CommonJS security-skill helpers are not an application layer. README's TypeScript mention describes Anthropic's official SDK; there is no local TypeScript package. Inspect actual manifests before adding such workflows.

| Responsibility | Source | Verification |
| --- | --- | --- |
| Public surface | `src/agent.zig` | `tests/client_test.zig` |
| Options, argv, CLI floor, permission names | `src/options.zig` | Inline tests, `tests/options_test.zig`, `scripts/canary.py` |
| Owned events/accessors | `src/event.zig` | Inline tests, `tests/event_test.zig` |
| Tool/permission signatures, registration | `src/tool.zig` | Inline tests, `tests/tool_test.zig` |
| Wire envelopes and raw JSON | `src/protocol.zig` | Inline tests, client fixtures |
| Spawn/read/control/state/lifecycle | `src/client.zig` | Inline tests, `tests/integration_test.zig` |
| POSIX pipe deadlines and child observation | `src/transport.zig` | Inline tests, `tests/transport_contract_test.zig` |
| Host demo and safe tool arguments | `examples/demo.zig`, `examples/demo_tools.zig` | Demo test root, `scripts/demo-smoke.py` |
| Complete consumer patterns | `examples/streaming.zig`, `examples/permissions.zig`, `examples/initialization.zig`, `examples/shutdown.zig` | `zig build examples-check` |

## Ownership and tests

- `Client.open` allocates a client; `close` destroys it. Join all client-using threads first. `wait`/`close` alone have no graceful-exit deadline; use `terminate(grace_ms)` for bounded shutdown.
- `next` returns a caller-owned `Event`/parsed tree that survives later reads. Accessor slices borrow it until `deinit`. `lastLine` instead lasts until the next read; `lastControlError` until the next rejection/close.
- Options slices, registrations, skills, and callback context are borrowed and must outlive the client. Argv storage is temporary and released after spawn.
- Callback arenas reset before each dispatch. Trace allocation -> callback -> serialization -> reset, including failures; copy data that must outlive dispatch.
- `src/agent.zig` is the supported import surface. Public tests use the `agent` module; non-re-exported/private declarations stay tested inline. A file belongs to one module and cannot import upward outside its module root.
- The three test roots are `src/agent.zig`, `tests/all.zig`, and `examples/demo.zig`; their explicit references make tests reachable. Add new black-box files to `tests/all.zig` and new Zig files under `src/`, `examples/`, or `tests/` to README Layout.
- Follow existing path headers and `zig fmt`. Optimization names are `ReleaseSafe`/`ReleaseFast`, not aliases from another repository.

## Framing and control state

- Trace complete-frame writes through protocol and transport. Partial writes/timeouts make transport terminal; later writes cannot resume a corrupted frame.
- CLI frames are untrusted data. Check fragmented/unterminated lines, malformed JSON, oversized-line discard, depth limits, unknown wire types, and ownership. `InvalidJson`/`ProtocolTooLong` allow the next line; `ProtocolTooDeep` terminates the session.
- Current defaults/limits: 32 MiB inbound line, 128 JSON containers, 16 KiB tool text, 16,896-byte complete reply including escaping/envelope/newline, and 16 pending requests. Pending initialization leaves 15 interrupt slots. Recheck source before citing numbers.
- Replies and fallbacks must obey the complete-frame cap and preserve correlation IDs. IDs cannot be truncated; an unrepresentable correlated fallback causes terminal `ReplyTooLong` and termination.
- MCP replies require `mcp_response`. Synthetic fixtures establish the client's expected envelope, not current installed-CLI acceptance.
- Tool schemas/replacement input are validated as JSON objects before raw splicing. Internal `result_json` is SDK-serialized. Check methods/names, unknown server/tool handling, and callback error-name disclosure.
- Match only accepted request IDs; inspect duplicates, unrelated replies, initialization preservation, and rejected interrupts. EOF without a result needs child exit-status inspection.

## Threads and process lifetime

- One `next` consumer; callbacks run under its non-reentrant read lock. Callbacks may send/terminate but cannot recurse into `next`.
- Lock order is write -> state; state never waits for an I/O lock. Inspect close/send/reply races and use synchronized `status`/`sessionId` instead of concurrently reading mutable fields.
- `closeStdin` shares the write lock and prevents closed/recycled-descriptor writes. Stdin must remain open through the final result and any background control work.
- Write timeout defaults to 5 seconds after obtaining the write lock, including initialization in `open`. Lock waits/callbacks have no API deadline; reply size bounds do not guarantee pipe progress.
- Termination cancels pipe I/O, sends SIGTERM to the direct child, escalates to SIGKILL after grace, and reaps under synchronization. Descendants may survive; inherited descriptors must not strand the SDK reader.
- PID observation/reap/signaling share state synchronization. Hosts must not independently reap the child; preserve SIGPIPE protection from default `std.Io.Threaded` initialization.
- Native macOS/Apple Silicon is validated. POSIX code or compilation does not establish Linux support; Windows is unsupported.

## Permissions and skills

- `SECURITY.md` defines a trusted in-process component, not a sandbox. `claude_path`/`PATH`, `extra_args`, settings, registrations, and callback code are trusted host authority. Model arguments and CLI frames require validation.
- `bare` changes discovery/setup/authentication, not tool authority. Inspect `tools`, `allowed_tools`, and `permission_mode` rather than claiming a sandbox.
- Permission handlers enable both stdio-routing flags and initialization. Proposed input is model-influenced. `.allow_with_input` replaces tool input; invalid JSON becomes denial, callback errors deny, and allocation failure also propagates.
- `skills = null` omits restrictions, empty permits no autonomous invocation, populated passes an initialize allowlist. Discovery is distinct from invocation: `sendCommand` is prompt text, and explicit `/name` dispatch bypasses the autonomous list.
- CLI discovery uses `.claude/skills/` via settings/additional directories/plugins. Repository `.agents/skills/` files are editor-agent skills; updating them does not install them into a CLI session.

## Validation, performance, and delivery

`just ci` runs formatting, README drift/Usage compilation, Debug/ReleaseSafe tests, and build. `scripts/gate.py` adds supervised ReleaseFast tests, Python tests, shell/hook syntax, docs, example compilation, offline compatibility, benchmark smoke, and demo argument smoke on macOS. `just ci-full` adds strict parser canary.

`scripts/runtime_validation.py` provides fresh per-root counts, race stress, fuzzing, and fingerprints. `scripts/processes.py` supervises tooling processes. Keep offline `scripts/compatibility.py`/`scripts/compatibility_fixture.py` evidence distinct from authorized live `scripts/live-compatibility.py`/`scripts/live_matrix.py` runs and their fixtures.

`bench/next_bench.zig` covers normal, escaped, large, control, and recovery workloads. For a baseline use `zig build bench -Doptimize=ReleaseFast -- 20000 all 5` with matching host/compiler/inputs; report medians, dispersion, latency percentiles, allocations/event, and peak/retained SDK memory. Startup/transcript/harness storage are excluded. Recovery checks memory after a 2 MiB event. Investigate repeatable throughput or allocation regressions above 10%; smoke is not a baseline. `scripts/bench_compare.py` supports seeded balanced before/after pairs with explicit executable/source metadata.

Manifest `.paths` defines shipped sources/docs; benchmarks, tooling, hooks, and `_dev/` are not shipped. Inspect `scripts/release_artifacts.py`, release shell entry points, and delivery tests for exact membership, clean-tree/version/changelog checks, SBOM/checksums, and optional signing. Releases run `ci-full` and stop before tagging/publication. Hashes/SBOM do not authenticate publishers without signer trust. Do not create releases or modify hooks merely to inspect them.
