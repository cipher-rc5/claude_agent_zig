# claude_agent_zig security review profile

Read this before selecting attack classes or planning a local reproduction. Recheck source declarations; this is navigation, not evidence. Read `SECURITY.md`, `CONTRIBUTING.md`, the manifest, and the actual build graph.

## Product and trust model

This is a standard-library-only Zig client of Claude Code CLI's bidirectional `stream-json` protocol. It spawns a child and exchanges NDJSON over pipes. It is a trusted in-process host component, not an HTTP service, tenant store, model runtime, or sandbox. It has no direct network I/O; the CLI, its tools, and registered callbacks may access external resources.

The checkout has no TypeScript sources/package manifest. Python/shell scripts implement delivery tooling; this skill's CommonJS files are report validators. Do not seed phantom web/API/database surfaces. Re-inventory real source/manifests if the project grows.

| Input/authority | Trace | Review focus |
| --- | --- | --- |
| Trusted host executable/configuration | `src/options.zig` -> spawn in `src/client.zig` | Host-selected PATH/claude_path/extra_args, discovery, permission modes |
| CLI/model-produced NDJSON | `src/transport.zig` -> framing/parsing in `src/client.zig` -> `src/event.zig` | Bounds/depth, malformed recovery, owned trees, terminal transport |
| MCP control requests and arguments | `src/client.zig`, `src/tool.zig`, `src/protocol.zig` | Server/tool lookup, argument types, response correlation, callback output |
| Permission requests | `src/client.zig`, `src/tool.zig`, `src/protocol.zig` | Callback decisions, JSON replacement validation, fail-closed errors |
| Concurrent host API calls | `src/client.zig`, `src/transport.zig` | Whole-frame locks, closed fd/PID reuse, cancellation/reap/destruction |
| Demo tool arguments | `examples/demo_tools.zig` | Non-secret environment allowlist, exact decimal strings, validation |
| Delivery/release inputs | `scripts/release_artifacts.py`, release shell scripts, `.githooks/`, `build.zig.zon` | Archive paths/membership, SBOM/checksums/signing, ref-tip gates |

Trusted callbacks/configuration choosing broad host access are not vulnerabilities by themselves. Neither is ordinary tool execution after an intentional `.bypass_permissions` choice. A security finding needs model/CLI/lower-trust input crossing an intended control with a concrete consequence; ordinary same-principal failure belongs in correctness findings.

## Select companions by actual boundary

Start with relevant blocks from these companions, not every block in each file:

- [Memory safety](MEMORY-SAFETY-AND-BINARY.md): owned events, borrowed option/registration slices, allocator failures, callback arenas, concurrency, fd/PID lifetime.
- [Protocol/RPC](PROTOCOLS-RPC-AND-MESSAGING.md): NDJSON framing, schemas, raw JSON splicing, request IDs, initialization/interrupt/MCP envelopes.
- [AI/tool authority](AI-AND-LLM.md): model-controlled tool input, host permissions, discovery/invocation distinctions, callback/error disclosure.
- [Resource limits](RESOURCE-EXHAUSTION-AND-AVAILABILITY.md): line/depth/reply limits, backpressure, pending slots, retained memory, cancellation and process cleanup.
- [Supply chain/release](SUPPLY-CHAIN-AND-RELEASE.md): exact compiler pin, external CLI, archive verifier, source membership, optional signer trust, local hooks.

Use local-IPC companion blocks only for applicable process/descriptor boundaries; pipes do not imply a listening desktop service. Browser, HTTP/auth, mobile, cloud/IAM, broker, and tenant-storage companions are out of scope unless current source adds those surfaces. Record source-backed exclusions in full-audit coverage.

## Invariants worth tracing

- `Event` owns its parse tree until `deinit`; accessor slices borrow it. `lastLine` and `lastControlError` have different client-owned lifetimes. Options/registrations/skills/context are borrowed through client lifetime; callbacks use a resettable dispatch arena.
- Tool schemas and permission replacement input must be JSON objects before raw splicing. Internal result JSON must remain SDK-serialized. Check newline/escaping behavior and all alternate/fallback replies.
- Recheck constants: 32 MiB default input line, 128-container depth, 16 KiB tool text, 16,896-byte complete reply including newline/escaping/envelope, and 16 pending requests shared with initialization.
- All replies preserve complete IDs and enforce the frame cap. If correlation cannot fit, `ReplyTooLong` is terminal rather than truncating identity or writing an oversized fallback.
- `InvalidJson` and `ProtocolTooLong` discard one line; excessive depth is terminal. Partial writes/deadlines disable transport so later frames cannot continue a corrupted stream.
- One `next` consumer; callbacks cannot reenter its read lock. Lock order is write -> state. Stdin close and writes serialize against descriptor reuse; reap/signals synchronize against PID reuse.
- Writes time out after lock acquisition (default 5 seconds), not while waiting for the lock or callback. Termination cancels pipe I/O and signals/reaps only the direct child. Join every client-using thread before `close`; arbitrary callback code cannot be forcibly canceled safely.
- Permission errors deny; invalid replacement JSON denies; OOM is also propagated. Check both permission-routing flags and initialization, and correlate every rejection/allow/deny.
- `bare` is not a tool sandbox. A skills initialize allowlist limits autonomous invocation, not discovery or explicit `/name` dispatch; null and empty differ. `.agents/skills/` is editor-agent discovery, distinct from the CLI's `.claude/skills/`.

## Local validation choices

Use exact Zig from `build.zig.zon` (currently 0.17.0), Python 3.12+, shell, and `just`. Supported native validation is macOS/Apple Silicon; Linux is untested, Windows unsupported. The sandbox requirements in `SKILL.md` still govern target execution; commands here are candidates, not an exemption.

- Prefer inline private tests or public black-box tests with scripted stub CLIs over real pipes: `tests/integration_test.zig`, `tests/transport_contract_test.zig`, and event/options/tool suites.
- Public tests import the `agent` module via `src/agent.zig`; internal tests stay inline. `build.zig` has roots at `src/agent.zig`, `tests/all.zig`, and `examples/demo.zig`. Confirm reachability/counts rather than assuming a file was tested.
- Focused test: `zig build test -Dtest-filter='name fragment' --summary all --test-timeout 10s`. `just compatibility` uses synthetic CLI fixtures. `just tooling-test` covers delivery/supervisor/bridge fixtures.
- `just ci` is formatting/docs/Debug/ReleaseSafe/build. `just ci-extended` is a supervised offline macOS gate and includes `ci`. `just ci-full` additionally requires strict parser probes. Passing any of these is not live model compatibility evidence.
- `just canary`/`just canary-strict` invoke the installed CLI parser but submit no model requests; do not substitute them for source or fixture proofs. The strict variant fails missing/inconclusive CLI checks.
- `just dev`, running live examples, and `just compatibility-live PATH` use real authentication/model quota. They are excluded from audit reproduction. Existing CLI login or environment credentials do not authorize their use.
- Keep stress/fuzz/benchmark checks bounded and relevant; use `scripts/runtime_validation.py`, `scripts/processes.py`, and `bench/next_bench.zig` where appropriate. Do not turn an offline gate into an adversarial availability test against a shared process.

## Private audit outputs

For a full audit, use a fresh `_dev/reviews/security_audit_<YYYYMMDD_HHMMSS>/` for the structured run files and isolated agent roots, after verifying the entire directory is ignored. Keep prior runs intact. If it is not ignored/writable, report the exact constraint and resolve it before writing; do not change ignore rules or force-add reports implicitly.

Also write the contributor-required sibling pair `_dev/reviews/critical_analysis_<YYYYMMDD_HHMMSS>.md` and `_dev/reviews/improvements_<YYYYMMDD_HHMMSS>.md`, using the same timestamp. The analysis summarizes scope/snapshot, confirmed IDs/priorities, validation, limitations, and links to the structured reports. The checklist gives one unchecked correction/observable acceptance check per confirmed root cause, grouped P0-P3; unresolved validation work stays separate. Source both from final validated records, never from draft candidates.

If scoring readiness, state the rubric and assessed coverage explicitly; use Not assessed outside the security scope. A clean findings list or passing schema does not imply production readiness. These private reports must not enter package archives or commits. Report findings privately as `SECURITY.md` requires; audit authorization does not authorize sending messages or publishing advisories.
