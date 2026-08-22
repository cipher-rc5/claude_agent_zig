# Improvements Checklist

**Generated from review:** _dev/reviews/001/critical_analysis.md
**Date:** 2026-08-22

---

## P0 — Blockers

- [ ] **[Legal]** Add a LICENSE file — the repo is public at `github.com/cipher-rc5/claude_zig` with no license, so it is legally all-rights-reserved and nobody may lawfully use or vendor it — repo root — Effort: S
- [ ] **[CI/CD]** Add `.github/workflows/ci.yml` running the existing gate (`just ci` = `fmt-check test build`); nothing currently enforces build, test, or format on any push — `justfile:43` — Effort: S
- [ ] **[Conventions]** Fix the false coverage claim: add `test { _ = @import("demo_tools.zig"); }` to `src/main.zig` so its test actually runs, or correct the comment — `build.zig:26-29` — Effort: S
- [ ] **[Error Handling]** Answer the CLI on all three malformed-envelope paths instead of returning silently; they violate the invariant stated at `README.md:179-181` and stall the CLI until timeout — `src/client.zig:262,265-266,267` — Effort: S
- [ ] **[API]** Make CLI failure detectable: a session whose child exits non-zero currently ends the read loop normally with zero events and no error — add a `wait()` accessor or surface a terminal error from `next()`, and stop teaching `defer _ = client.close()` — `src/client.zig:94`, `README.md:134` — Effort: M

## P1 — Pre-release

- [ ] **[Safety]** Make `error.ProtocolTooLong` either recoverable (discard through the next `\n` before returning) or explicitly terminal (latch the client dead and document it); it is currently permanently stuck with no documentation — `src/client.zig:345-366` — Effort: M
- [ ] **[Testing]** Add tests to `src/client.zig` — currently 0 tests on the 367-line module holding all framing, dispatch, and lifecycle logic — Effort: L
- [ ] **[Testing]** Extract `readLine(line, reader, max)` as a free function so framing is testable against `Io.Reader.fixed(...)`; covers EOF, no-trailing-newline, and oversized-line paths — `src/client.zig:345-366` — Effort: M
- [ ] **[Testing]** Give the four `send*` helpers a `*Io.Writer` parameter so `serveControlRequest` can be driven with `Io.Writer.Allocating` and asserted with the existing `expectContains` harness at `protocol.zig:283` — `src/client.zig:221-257` — Effort: M
- [ ] **[Testing]** Add failure-path tests for the seven uncovered paths: malformed JSON, unknown control subtype, handler error, oversized line, EOF mid-line, unknown server/tool, missing params — Effort: M
- [ ] **[API]** Document the borrowed-slice lifetime requirement for `sdk_mcp_servers` and `skills` in the README and on the `Options` fields; the README's own example uses a local array — `src/client.zig:42-44`, `options.zig:78-81`, `README.md:102` — Effort: S
- [ ] **[Safety]** Replace the `std.debug.assert` guard on `send()` after `closeStdin()` with a returned error; asserts compile out in release and the writer holds a stale fd copy — `src/client.zig:125` — Effort: S
- [ ] **[Error Handling]** Bound `close()`'s `child.wait()` with a timeout then `kill`; a hung child hangs the host forever and the existing `catch`-then-`kill` is unreachable in that case — `src/client.zig:96-99` — Effort: M
- [ ] **[Docs]** Correct the `bare` claims — the CLI's own help says "Skills still resolve via /skill-name", contradicting "disables skill discovery outright"; stated as a safety property in two places — `README.md:34-36,62-63`, `src/options.zig:32-37` — Effort: S
- [ ] **[CI/CD]** Add a scheduled canary job against the current Claude Code CLI; this client's correctness is pinned to an externally-versioned wire protocol and nothing detects drift — Effort: M

## P2 — Should-fix

- [ ] **[Error Handling]** Stop collapsing `OutOfMemory` into `error.WriteFailed`; the two demand opposite remediations and `ReadError` already carries `OutOfMemory` — `src/client.zig:183` — Effort: S
- [ ] **[Error Handling]** Separate host-fatal errors from handler-domain errors instead of stringifying every `anyerror` into agent-visible tool text — `src/client.zig:327-330` — Effort: S
- [ ] **[Concurrency]** Reconcile the arena-reset contract: `tool.zig:14-15` documents reset-after-write, the code resets before the handler runs — `src/client.zig:285` — Effort: S
- [ ] **[Concurrency]** Document that `Client` is not thread-safe, and either make `interrupt()` safe for cross-thread use or state that it cannot be — `src/client.zig:31-48,142` — Effort: S
- [ ] **[API]** Expose the captured `session_id` (it is allocated and freed but unreachable) so `Options.resume_session_id` is usable without re-scraping events — `src/client.zig:47,101,174-176` — Effort: S
- [ ] **[API]** Declare an explicit error set for `send`, `sendCommand`, and `interrupt` instead of inferring through `std.json.Stringify` — `src/client.zig:124,133,142` — Effort: S
- [ ] **[Docs]** Remove or annotate the `--permission-prompt-tool stdio` note; the flag does not exist in CLI v2.1.228 — `README.md:176-178` — Effort: S
- [ ] **[Docs]** Document the justfile and the `AGENT_SKILLS` env var in the README; `AGENT_SKILLS` is read at `src/main.zig:28,42` but appears nowhere in the README — `README.md:183-189` — Effort: S
- [ ] **[Docs]** Document the public `interrupt()` method, currently absent from the README — `src/client.zig:142` — Effort: S
- [ ] **[Docs]** Add CHANGELOG.md; the version is pinned at `0.1.0` against a moving CLI target — Effort: S
- [ ] **[Concurrency]** Add a targeted test writing a >64 KB *tool result* to rule out (or confirm) the stdin-flush/stdout-backlog deadlock mechanism; the inbound direction is verified clean, the outbound direction is untested — Effort: M

## P3 — Nice-to-have

- [ ] **[Safety]** Add an integer fast-path to `numberOf` so `add` does not lose precision above 2^53; demo code, but it is the pattern consumers copy — `src/demo_tools.zig:33-38` — Effort: S
- [ ] **[Docs]** Add SECURITY.md; the library spawns a subprocess, splices caller-supplied raw JSON into the wire protocol, and runs caller-registered handlers — Effort: S
- [ ] **[Docs]** Add CONTRIBUTING.md pointing at `just ci` as the pre-commit gate — Effort: S
- [ ] **[Dependencies]** Add a license field to `build.zig.zon` once a LICENSE exists, after confirming the 0.16 manifest schema accepts it — `build.zig.zon:1-12` — Effort: S
- [ ] **[API]** Expose `bypassPermissions` in `PermissionMode`, or document its omission as deliberate — `src/options.zig:9-14` — Effort: S
- [ ] **[Performance]** Drop the `Allocating` buffer in `sendCommand` and write the `/name args` prefix straight to the stdin writer — `src/client.zig:134-138` — Effort: S
- [ ] **[Error Handling]** Add an `errdefer` for the parsed tree on the `session_id` dupe failure path — `src/client.zig:175` — Effort: S
- [ ] **[Conventions]** Note that `McpServer.version` and the package version are intentionally decoupled despite both reading `"0.1.0"` — `src/tool.zig:35` — Effort: S
- [ ] **[Docs]** Document that `--verbose` is unconditional and cannot be removed via `extra_args` — `src/options.zig:110` — Effort: S

---

## Progress

**Total items:** 34
**P0:** 5 | **P1:** 10 | **P2:** 11 | **P3:** 9
