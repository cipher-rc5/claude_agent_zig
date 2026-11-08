---
name: cipher-review
description: Review production readiness of the claude_agent_zig SDK when asked for a cipher review or production readiness review. Assess Zig ownership, stream-json and MCP handling, permissions, subprocess lifecycle, local gates, and release integrity; write private scored reports under _dev/reviews/.
---

# Cipher Review - Claude Agent SDK for Zig

Review the current working tree as a Zig library driving the Claude Code CLI over bidirectional NDJSON pipes. Read `CONTRIBUTING.md` and `SECURITY.md` first. A review request authorizes private reports and isolated validation; implement fixes only when also requested. Editing this skill does not request a review.

## Establish the snapshot

- Read applicable agent rules, `README.md`, `CHANGELOG.md`, `build.zig`, `build.zig.zon`, `justfile`, and relevant tooling. Use [the codebase map](references/codebase.md) to select paths; verify its claims against the checkout.
- Record timestamp/timezone, full HEAD, branch or detached state, `git status --short`, diff summary, OS/architecture, and actual tool versions. Include relevant untracked first-party files. A dirty snapshot needs more than a commit ID; hash reproduction and benchmark inputs. Recheck source status at the end and disclose concurrent changes.
- Follow `CONTRIBUTING.md`: write `_dev/reviews/critical_analysis_<YYYYMMDD_HHMMSS>.md` and `_dev/reviews/improvements_<YYYYMMDD_HHMMSS>.md`, sharing one timestamp, plus `evidence_<YYYYMMDD_HHMMSS>/`. Create paths exclusively; choose another timestamp on collision. Verify they are ignored with `git check-ignore`; never force-add them.
- Do not read prior reviews or improvement notes until independent findings and initial scores are written. Historical logs are context, not fresh evidence.

## Trace the SDK contracts

Inventory `src/`, `tests/`, `examples/`, `bench/`, `scripts/`, build files, and `.githooks/`. This checkout has Zig library code, Python/shell tooling, and CommonJS audit helpers. It has no TypeScript application or package manifest. Inspect actual manifests if that changes; do not invent frontend checks, database migrations, or HTTP routes.

Read implementations, callers, and tests together. Trace:

1. `Options` -> argv -> spawn/initialization -> startup failure and rejection cleanup.
2. `send`/`sendCommand`/`interrupt` -> serialized complete-frame write -> request correlation and pending-slot limits.
3. Pipe read -> newline framing/JSON limits -> caller-owned `Event` -> accessor lifetime -> `deinit`.
4. MCP registration/list/call -> argument validation/lookup -> synchronous callback -> bounded result or error reply.
5. `can_use_tool` -> permission handler -> allow/deny/replacement -> validated, correlated reply.
6. EOF, malformed lines, backpressure, partial writes, interruption, and termination -> cancellation -> reap -> thread joins -> destruction.
7. Settings/skill discovery -> initialize allowlist -> explicit dispatch, including null versus empty options.

Check allocation failures, borrowed slices, callback arena resets, descriptor/PID reuse, lock order, and cleanup. Matches such as `catch {}`, casts, assertions, and `unreachable` are leads; establish reachable consequences before reporting defects. Maintain a coverage table with traced behavior, evidence, and unread/untested paths.

## Gather fresh evidence

Use the exact compiler pin from `build.zig.zon` (currently Zig 0.17.1); `build.zig` enforces equality. Native macOS/Apple Silicon is the supported validated platform; Linux is untested and Windows unsupported.

| Purpose | Existing command |
| --- | --- |
| Canonical local gate | `just ci` |
| Supervised offline macOS validation | `just ci-extended` |
| Focused regression | `zig build test -Dtest-filter='name fragment' --summary all --test-timeout 10s` |
| Compile complete consumer examples | `zig build examples-check` |
| Synthetic protocol fixtures | `just compatibility` |
| Python delivery-tool tests | `just tooling-test` |
| Installed CLI parser checks, no model use | `just canary` or `just canary-strict` |
| Fresh stress/fuzz/native evidence when relevant | `just runtime-validate _dev/validation/<new-run>` |

- For a full readiness review run `just ci-extended` once when prerequisites permit; it includes `just ci`. Narrow user scope may justify focused checks. Inspect `scripts/gate.py` for actual stages; do not repeat passing gates without a new reason.
- Save full logs, real exit codes, and deadlines. Distinguish failed, skipped, not reached, cached, and freshly executed checks. Toolchain/sandbox failures are validation limits until a code defect is established.
- Verify tests are reachable from the three roots: `src/agent.zig`, `tests/all.zig`, and `examples/demo.zig`. Check matching test counts; a filtered build can succeed with zero tests.
- Reuse scripted stub CLIs and synthetic fixtures over real pipes, scratch paths, and bounded supervisors. Do not invoke `just dev`, live examples, or `just compatibility-live` without authorization for model use. Parser acceptance, synthetic compatibility, and live CLI behavior establish different facts.
- Neither `ci` nor `ci-extended` includes strict canary checks; `just ci-full` combines the extended gate and strict parser probes. Do not call ordinary CI release validation.
- Isolated probes should use dedicated output prefixes if a normal executable may be in use. Do not install hooks/schedules, alter login state, create releases/tags, publish, or push during review.

For decisive checks save command, cwd, non-secret overrides, timestamp/duration, source/input hashes, exit code, expected/actual result, and log path. Do not capture credentials or ambient environments.

## Check API, docs, and delivery

- `src/agent.zig` is the supported public API. A sibling module's `pub` declaration is not automatically SDK surface. Public black-box tests use `@import("agent")`; internal tests stay inline. Do not widen API to move tests.
- Check README Layout membership, compiling Usage blocks, complete examples, re-export tests, and `[Unreleased]` notes for consumer-visible changes. `just docs-check` checks specific contracts, not all prose.
- Compare emitted flags with `scripts/canary.py` and options-derived CLI floor/permission modes. Do not change the floor merely to pass a local probe.
- Inspect `scripts/release.sh`, `scripts/release-verify.sh`, `scripts/release_artifacts.py`, and manifest `.paths`: dirty-tree/version/changelog checks, exact archive/SBOM membership, and optional signing. Checksums prove integrity; publisher authentication needs configured signer trust.
- There are no package dependencies beyond Zig's standard library. The compiler and separately installed CLI remain supply-chain/compatibility inputs. Research current upstream claims from primary sources when needed; disclose unavailable evidence. Do not invent vendored dependencies or add packages.
- Hosted CI is intentionally absent. Pre-commit checks the working tree; pre-push checks distinct pushed ref tips in temporary worktrees. Hooks are opt-in and bypassable, not remote enforcement.

Extract applicable product/contributor requirements and mark **Met**, **Violated**, **Not verified**, or **Not applicable**, with source and evidence. Apply ancestor rules to the technology/action they govern; unrelated TypeScript service conventions are not SDK requirements.

## Confirm and score

A confirmed finding needs a reachable trigger, root cause, observed or code-proven consequence, and concrete correction. Label static proof accurately. Keep unresolved hypotheses outside confirmed counts. Assign each root cause one ID (`CR-001`, etc.), primary dimension, severity, and priority; cross-reference rather than duplicate it.

| Dimension | SDK focus |
| --- | --- |
| Safety & Correctness | Event/option lifetimes, JSON/framing invariants, descriptor/PID safety |
| Error Handling | Startup/rejection errors, recoverable lines, terminal writes, callback failures |
| API Design | Public module, null/empty semantics, ownership and lifecycle contracts |
| Concurrency | Read/write/state locks, callback reentrancy, cancellation, reap/destruction |
| Testing | Reachable roots, real-pipe stubs, allocation failures, stress/fuzz/native evidence |
| Performance | Event latency/allocations, reply bounds, backpressure, retained memory |
| Documentation | Examples, discovery/permissions, deadlines and host cleanup responsibilities |
| CI/CD & Release | Local gates/hooks, package membership, integrity and optional signing |
| Dependency Hygiene | Exact Zig pin, standard-library-only package, external CLI compatibility |
| Conventions | Zig formatting/path headers, test placement, private reports, changelog |

Readiness rubric: **1-3** critical failure/unsafe core behavior; **4-5** significant confirmed gaps including High findings; **6-7** normal paths work but material correctness/resilience/validation gaps remain; **8-9** affirmative normal/failure-path evidence with minor gaps; **10** exceptional evidence and no meaningful gaps within comprehensive stated coverage. Report coverage/confidence separately.

Critical findings cap materially affected dimensions at 3; High caps them at 5. Use **Not assessed** without sufficient evidence. Average numeric scores to one decimal and disclose assessed count. Passing gates alone do not justify 8+; historical scores are not targets.

Severity follows demonstrated consequence: **Critical** substantial corruption/disclosure/destructive execution; **High** major supported-workflow failure or significant resource/authority exposure; **Medium** bounded functional/operational degradation; **Low** limited-impact defect. Security findings also need a violated boundary; use `SECURITY.md` to distinguish intended host authority from vulnerabilities.

Priority is separate: **P0** blocks safe supported use/release; **P1** before next release; **P2** planned cycle; **P3** optional improvement. Explain differences from severity. Missing hosted CI or intentionally trusted callbacks are not inherently blockers.

## Write and reconcile

Use [the reporting contract](references/reporting.md) for both timestamped artifacts. Check citations, arithmetic, unique IDs, priorities/counts, and acceptance checks. Recheck findings against counterevidence. Only now consult history if useful, independently revalidating adopted root causes.

Finish with both report links, score/assessed count, confirmed blockers or their absence, P0-P3 counts, and material validation limits. A completed report does not make an unverified SDK production-ready.
