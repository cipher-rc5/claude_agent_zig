# Critical Analysis

**Date:** 2026-08-22
**Commit:** a93433c
**Branch observed:** main
**Reviewer:** Claude Code (automated)
**Model:** Opus 5 (claude-opus-5)
**Provider:** Anthropic API
**Thinking level:** none

---

## Composite Score: 5.4 / 10

| Dimension | Score | Severity |
|-----------|-------|----------|
| 1. Safety & Correctness | 6/10 | Medium |
| 2. Error Handling | 5/10 | High |
| 3. API Design | 5/10 | High |
| 4. Concurrency | 5/10 | High |
| 5. Testing | 4/10 | High |
| 6. Performance | 7/10 | Medium |
| 7. Documentation | 6/10 | Medium |
| 8. CI/CD & Release | 2/10 | Critical |
| 9. Dependency Hygiene | 9/10 | Low |
| 10. Conventions | 5/10 | High |

Severity column: **Critical** = score 1-3, **High** = 4-5, **Medium** = 6-7, **Low** = 8-9, **None** = 10.

---

## Top Blockers

1. **No LICENSE file, and the repository is public.** The remote is `https://github.com/cipher-rc5/claude_zig.git`. Absent a license, copyright defaults to all-rights-reserved: no third party may lawfully use, modify, redistribute, or vendor this code. `build.zig.zon:1-12` carries no license field either. This defeats the project's stated purpose of being a consumable SDK and is a one-file fix. [Critical]

2. **No CI whatsoever.** There is no `.github/` directory. Verified: `ls -R .github` → no such directory. Nothing enforces build, test, or format on any push or PR — despite `justfile:43` already defining the exact gate (`ci: fmt-check test build`). For a client whose correctness is pinned to an externally-versioned CLI protocol, there is also no canary to detect wire-format drift when Claude Code releases. [Critical]

3. **A failed CLI session is indistinguishable from a successful empty one.** Verified by running a client against a stub that exits 7: `events seen = 0; loop ended NORMALLY (no error)`, and the only failure signal is `close()` returning `Term{.exited = 7}` — which the README's own example at `README.md:134` discards via `defer _ = client.close();`. A user following the documented pattern gets a silent success from a session that never started. This is the most common real-world failure (expired auth, version skew). [High]

4. **`error.ProtocolTooLong` is permanently unrecoverable and undocumented as terminal.** Verified: after the error fires, every subsequent `next()` returns `error.ProtocolTooLong` forever — the reader never resyncs past the oversized line. `client.zig:353` maps the error but discards nothing, so the remainder of the line stays in the pipe. Nothing in the public docs or the `ReadError` set marks this as fatal rather than retryable. [High]

5. **Three control-request paths return without answering the CLI, contradicting the module's own stated invariant.** `client.zig:262`, `:265-266`, and `:267` each `orelse return` on a malformed envelope. `README.md:179-181` states the design guarantee: "an unsupported control request gets an error response rather than silence, so the CLI does not hang." These three paths produce exactly that silence, stalling the CLI until its own timeout. [High]

6. **`build.zig` makes a false coverage claim and one test never runs.** `build.zig:26-27` comments that "src/agent.zig pulls in every library module, and src/main.zig reaches the demo tools, so between them the two roots cover the whole tree." Verified false: `zig test src/main.zig` → **"All 0 tests passed."** `src/main.zig` has no `test` block and no `_ = @import("demo_tools.zig")`, so `demo_tools.zig:63` has never executed. The suite reports 19/19 passing while silently running 19 of 20. [High]

---

## Dimension Findings

### 1. Safety & Correctness — 6/10

The framing and lifecycle logic is better than its lack of tests would suggest. I verified the highest-risk paths by driving a real `Client` against stub CLIs rather than reasoning from inspection.

Verified sound: end-of-stream detection at `client.zig:345-366` handles a final line without a trailing newline (2/2 events), a stream ending exactly at a delimiter (clean `null`, no spurious empty line), and a 200 KB single line far exceeding the 64 KB `stdout_buffer` (read complete, `resultlen=200000`). A missing `claude` binary surfaces cleanly as `error.FileNotFound` at `open()` rather than being deferred to `next()`. The `errdefer` chain in `open` (`client.zig:54-72`) is correctly ordered across all five fallible acquisitions. `catch unreachable` at `client.zig:197` is provably safe — max output is 14 bytes into a `[32]u8`.

The defects are in the error paths, not the happy path.

**Issues:**
- `src/client.zig:345-366` — `error.ProtocolTooLong` leaves the reader positioned mid-line with no resync; verified that all subsequent `next()` calls return the same error permanently, with no documentation that the error is terminal. [High]
- `src/client.zig:262,265-266,267` — three `orelse return` paths answer nothing, violating the no-silence invariant asserted at `README.md:179-181` and stalling the CLI until timeout. [High]
- `src/client.zig:125` — `std.debug.assert(!client.stdin_closed)` is the only guard on `send()` after `closeStdin()`. Asserts compile out in `ReleaseFast`/`ReleaseSmall`. `Io.File.Writer` stores the file by value (`std/Io/File/Writer.zig:11`), so the writer retains a copy of the fd number that `closeStdin` cannot null; a post-close `send` in a release build writes to a closed — and potentially recycled — descriptor. `send` already returns `!void`, so a real error costs nothing. [Medium]
- `src/demo_tools.zig:33-38` — `@floatFromInt` from `i64` to `f64` loses precision above 2^53; `{"a": 9007199254740993, "b": 0}` returns `9007199254740992`. Demo-only, but it is the pattern every consumer copies when writing handlers. [Low]

---

### 2. Error Handling — 5/10

Error *types* are thoughtfully constructed; error *propagation* discards information at three points, and two of those conflate host-fatal conditions with recoverable ones.

**Issues:**
- `src/client.zig:183` — `client.serveControlRequest(...) catch return error.WriteFailed;` collapses at least three distinct classes into one. `error.OutOfMemory` (from the `Io.Writer.Allocating` at `:253`) becomes `WriteFailed`, telling the caller "the child died, restart the session" when the truth is "this host is out of memory" — the retry is precisely the wrong remediation. `ReadError` already contains `OutOfMemory`, so propagating it costs nothing. [Medium]
- `src/client.zig:327-330` — the blanket `catch |err| ToolResult{ .text = @errorName(err), .is_error = true }` launders host-fatal `OutOfMemory` into agent-visible tool text and continues the session in a degraded state. It also pipes arbitrary internal error identifiers from third-party handler code into the model's context. [Medium]
- `src/client.zig:96-99` — `close()` calls `child.wait()` with no timeout. The `catch` only fires if `wait` *returns an error*, which a hung-but-alive child never does, so `child.kill` at `:97` is unreachable in exactly the case that needs it. A wedged CLI hangs the host process indefinitely. [Medium]
- `src/client.zig:96-99` — when `wait` does fail, the function returns `Term{ .unknown = 0 }`, indistinguishable from a genuine `.unknown` exit; the underlying error is lost. [Low]
- `src/client.zig:175` — `gpa.dupe` for `session_id` can return `error.OutOfMemory` without freeing the already-parsed `parsed` tree. Only reachable under allocator exhaustion, but an `errdefer` would close it. [Low]

---

### 3. API Design — 5/10

The `Options` surface is well-documented and the null-vs-empty `skills` modelling is genuinely careful. The lifecycle surface is where the foot-guns are, and the README teaches one of them directly.

**Issues:**
- `src/client.zig:94` + `README.md:134` — `close()` returns `Term`, and the documented usage discards it. Zig has no `must_use`, and `defer _ = client.close()` is the only way to use it in a `defer`, so the API funnels users into ignoring the one available failure signal. Verified: a CLI exiting 7 yields zero events, a normal loop exit, and no error. [High]
- `src/client.zig:42-44` — `servers` and `skills` are borrowed from `Options`; the lifetime requirement appears only in an internal comment. Neither `README.md` nor the `Options` field docs at `options.zig:78-81` mention it. `README.md:102` shows `const servers = [_]agent.McpServer{...}` as a local — a user who wraps `open` in a helper gets a dangling pointer that compiles clean, survives the in-`open` handshake, and corrupts only later at `client.zig:282` when the model first calls a tool. [High]
- `src/client.zig:142` — `interrupt()` exists to abandon an in-flight turn, which by definition requires calling it while another thread sits in `next()`. `Client` has no synchronization (see Concurrency), so the one method shaped for cross-thread use cannot be safely used cross-thread. It is also absent from the README entirely. [Medium]
- `src/client.zig:47,101,174-176` — `session_id` is captured and heap-allocated on every session and freed in `close`, but has no public accessor, while `Options.resume_session_id` (`options.zig:83`) exists to resume by id. Users must re-scrape it from `Event.sessionId()`; the field is otherwise dead weight. [Medium]
- `src/client.zig:124,133,142` — `send`, `sendCommand`, and `interrupt` return inferred `!void` while `OpenError` and `ReadError` 100 lines above are hand-declared. The inferred sets resolve through `std.json.Stringify`, so a stdlib change silently widens the public API. [Medium]

---

### 4. Concurrency — 5/10

The single-threaded contract is real, coherent, and honestly documented at `README.md:169-172`; I verified that `serveControlRequest` is called from exactly one place (`client.zig:183`) inside `next()`. The problem is that the contract is stated for *pumping* but never for *thread safety*, and one shipped method presupposes the opposite.

**Issues:**
- `src/client.zig:31-48` — no mutex or atomics guard `line`, `scratch`, `next_request_id`, `session_id`, `stdin_closed`, or either stream interface. Concurrent `send`/`next` interleaves two JSON objects on one line and makes `next_request_id++` at `:196` a racing read-modify-write that can mint duplicate request ids. The README documents the pumping limitation but never states "not thread-safe". [Medium]
- `src/client.zig:285` vs `src/tool.zig:14-15` — the handler contract says the arena "is reset after the result is written"; the implementation resets at the *top* of dispatch, before the handler runs. Behaviorally the peak is still bounded (`retain_capacity` converges to the largest single result), but the documented contract and the code disagree, and the last call's memory stays resident until `close()`. [Medium]
- `src/client.zig:183` — dispatch is inline in the read loop, so a blocking handler stalls the entire session with no timeout, no cancellation, and no way to abort. If the handler outlives the CLI's own control-request timeout, the reply is discarded and the session desynchronizes. [Medium]
- A pipe-deadlock risk was raised during review: the client alternates strictly between reading stdout and a blocking flush to stdin, so a large tool reply written while the CLI has an undrained stdout backlog could in principle wedge both processes. I could not reproduce it — a 200 KB inbound line round-tripped cleanly — so I am recording the mechanism as plausible and unverified rather than as a confirmed defect. It warrants a targeted test with a >64 KB *tool result*, which is the untested direction. [Low]

---

### 5. Testing — 4/10

19 tests pass. The distribution is the problem: every test targets a pure function, and the module that fails silently has none.

Coverage by file: `protocol.zig` 11, `options.zig` 3, `event.zig` 3, `tool.zig` 1, `demo_tools.zig` 1 (never executed), **`client.zig` 0**. `client.zig` is 367 lines — 27% of the 1383-line tree — and holds all the stateful, failure-prone logic: framing, control dispatch, process lifecycle, session capture.

The protocol tests are good tests. They pin load-bearing, non-obvious details: the `mcp_response` wrapper (`protocol.zig:330`), raw splicing versus re-encoding (`:334`, `:380`), exact camelCase spellings (`:319`). But they verify that the writers *render* correctly, never that the dispatcher *calls* them with the right arguments for the right input.

Testability is not the obstacle. `nextLine` depends only on `*Io.Reader`, already an interface — extracting it to a free function taking `(line, reader, max)` makes it testable against `Io.Reader.fixed("a\nb\n")` with no behavior change. `serveControlRequest` is private and takes a `std.json.Value`, so a same-file test can call it directly; only the four `send*` helpers need a `*Io.Writer` parameter instead of reaching through `client`. The `render`/`expectContains` harness at `protocol.zig:275-288` is exactly the needed scaffolding and simply was never pointed at the dispatch layer.

**Issues:**
- `src/client.zig` (entire file) — zero tests on the highest-risk module. Every defect in dimensions 1-4 above lives here and would have been caught by a dispatch or framing test. [High]
- `build.zig:26-29` + `src/main.zig` — the second test root runs nothing. Verified: `zig test src/main.zig` → "All 0 tests passed." Zig only runs tests reachable from the root's import graph via `_ = @import(...)` or `refAllDecls`; `main.zig` has a plain `@import` at line 7 and no `test` block, so `demo_tools.zig:63` has never run. The summary line reads as coverage that does not exist. One-line fix. [High]
- No failure-path tests exist for: malformed JSON (`client.zig:165-168`), unknown control subtype (`:269-273`), handler error (`:327-330`), oversized line (`:353`), EOF mid-line (`:360-363`), unknown server/tool (`:282`, `:324`), missing params (`:318-321`). Seven enumerated paths, zero coverage. [High]
- No test asserts the `session_id` dupe/free pairing (`client.zig:175`, `:101`), so a leak there is invisible. [Low]

---

### 6. Performance — 7/10

Appropriate for a subprocess-bound client, where the dominant cost is the child process and the network behind it. No hot loops, no gratuitous copying, and the buffer sizes (`options.zig:87-90`) are sensible. The scratch arena's `retain_capacity` reset converges to a single chunk sized to the largest result rather than growing per call — I traced `ArenaAllocator.reset` to confirm. Raw splicing of `input_schema` and `result_json` (`protocol.zig:150-152`, `:233-235`) avoids a re-encode pass. Event parsing to `std.json.Value` rather than fixed structs costs allocation per line but is the right trade for a schema that gains fields per CLI release, and `README.md:160-162` states that reasoning.

**Issues:**
- `src/client.zig:134-138` — `sendCommand` allocates an entire `Io.Writer.Allocating` solely to prefix `/`; it could write directly to the stdin writer, dropping both the allocation and `Allocator.Error` from its inferred error set. [Low]
- `src/client.zig:285` — the last tool call's arena memory stays resident for the client's lifetime rather than being released after the reply is written. Bounded, but it is the high-water mark of the largest single result. [Low]
- No benchmarks exist. Defensible for a subprocess-bound client, and I am not treating their absence as a gap. [Low]

---

### 7. Documentation — 6/10

The README is unusually substantive for a project this size, and most of it is accurate. I verified the load-bearing claims rather than trusting them: the Layout table matches `ls src/` exactly (8 files, no orphans, no omissions); the Usage example at `README.md:127-144` compiles verbatim against the real API, including the `io` parameter; the in-process tool example's field names all match `tool.zig`; `sendCommand`'s signature matches `client.zig:133`; "No dependencies beyond the standard library" matches `build.zig.zon:6`; and the `streamDelimiterLimit`, `mcp_response`, and heap-allocation notes all match their implementations. That is a high accuracy rate.

The drift that exists is concentrated in claims about `--bare`, which are stated as a safety property.

**Issues:**
- `README.md:34-36,62-63` and `src/options.zig:32-37` — the claim that `bare` "narrows the built-in set... so WebSearch, WebFetch, Agent and Skill are simply not registered" and "disables skill discovery outright" contradicts the CLI's own `--bare` help text in v2.1.228, which states **"Skills still resolve via /skill-name"** and describes only skipping hooks, LSP, plugin sync, attribution, auto-memory, prefetches, keychain reads, and CLAUDE.md discovery. A user treating `bare = true` as a boundary guaranteeing WebSearch/WebFetch are unavailable is relying on an unverified property. Duplicated in two places. [Medium]
- `README.md:176-178` — cites `--permission-prompt-tool stdio` as the forward path for permission callbacks. Grepping the full help output of CLI 2.1.228 returns zero matches for `permission-prompt`; the flag is not in the current surface. Stale roadmap note, not a runtime break. [Medium]
- `README.md:183-189` — the Build section documents only `zig build`/`zig build test`/`zig build run` and never mentions the tracked `justfile`, which is the sole documentation for the `AGENT_SKILLS` environment variable that `src/main.zig:28,42` actually reads. A contributor cannot discover `just ci` or `AGENT_SKILLS` from the README. [Low]
- `src/client.zig:142` — `interrupt()` is public API with wire-format tests and no README coverage at all. [Low]
- `src/options.zig:110` — `--verbose` is appended unconditionally and cannot be removed via `extra_args`; not documented as a constraint. With stderr inherited (`client.zig:70`), that output reaches the user's terminal. [Low]
- No CHANGELOG.md. With the version pinned at `0.1.0` and the protocol tracking a moving CLI target, consumers have no record of what changed between revisions. [Low]

---

### 8. CI/CD & Release — 2/10

Nothing exists. This is the weakest dimension by a wide margin and the two blockers above both live here.

There is no `.github/` directory, therefore no workflows, no branch protection to verify against `main`, no release automation, no checksums, no signing, no SBOM, and no dependency-audit step. The active branch is `main` and the working tree is clean at `a93433c`, so there is no drift between what is committed and what was reviewed — but nothing verifies any future commit.

The gap is unusually cheap to close: `justfile:43` already encodes the gate as `ci: fmt-check test build`, all three of which I ran and all three pass. A workflow calling `just ci` would be a few lines.

**Issues:**
- No `.github/workflows/` — no automated build, test, or format enforcement on any push or PR. [Critical]
- No scheduled canary against the Claude Code CLI. This client's correctness is pinned to an externally-versioned wire protocol it does not control; a CLI release changing the control-request shape breaks it silently, and nothing would detect that. This is the project's single largest ongoing risk. [High]
- No release process at all: no tags, no checksums, no signing, no SBOM. `build.zig.zon` is pinned at `0.1.0`. [Medium]

---

### 9. Dependency Hygiene — 9/10

The strongest dimension, and it is strong affirmatively rather than by absence of findings. `build.zig.zon:6` declares `.dependencies = .{}` — genuinely zero external dependencies, matching the README's claim exactly. The entire client is built on the Zig standard library, which eliminates supply-chain surface, version-pinning drift, and transitive-license exposure outright. `minimum_zig_version = "0.16.0"` is declared and matches both the local toolchain and the README. Build artifacts (`zig-out/`, `.zig-cache/`) are correctly gitignored and absent from `git ls-files`.

**Issues:**
- `build.zig.zon:1-12` — no license field, so even once a LICENSE file exists, package consumers get no machine-readable signal. Worth confirming against the 0.16 manifest schema before adding, since Zig rejects unknown manifest fields. [Low]

---

### 10. Conventions — 5/10

File-level conventions are followed consistently: all 8 source files carry a correct `// src/<name>.zig` header matching their own filename, `build.zig:1` follows the same pattern, naming is uniformly snake_case for fields and camelCase for functions, and the deliberate camelCase wire literals (`sdkMcpServers`, `inputSchema`, `protocolVersion`, `isError`) are correct because the CLI is strict about them — `protocol.zig:315` documents that explicitly. `zig fmt --check build.zig src` passes clean. No TODO/FIXME/HACK/XXX markers anywhere. No lint suppressions. No dead code: every `pub fn` is called, re-exported through `agent.zig`, or documented public API.

The score is capped by two verified cases where the code contradicts a rule the project states about itself — the category this dimension exists to catch.

**Issues:**
- `build.zig:26-27` — the comment asserts the two test roots "cover the whole tree." Verified false; `zig test src/main.zig` runs 0 tests. A structural claim in the build definition that does not hold. [High]
- `src/tool.zig:14-15` vs `src/client.zig:285` — the documented handler contract ("`arena` is reset after the result is written") contradicts the implementation, which resets before the handler runs. [Medium]
- `README.md:179-181` vs `client.zig:262,265-267` — the stated no-silence invariant is violated by three paths in the function it describes. [High]
- `src/options.zig:9-14` — `PermissionMode` omits the CLI's `bypassPermissions`, which the live CLI accepts. Reachable via `extra_args`, and plausibly a deliberate safety choice, but undocumented as such. [Low]
- `src/tool.zig:35` — `McpServer.version` defaults to the literal `"0.1.0"`, coincidentally matching `build.zig.zon:3`'s package version. Unrelated concepts sharing a literal; bumping the package version will silently leave this behind. [Low]

---

## Verified Policy-Rule Compliance

No `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `.cursorrules`, or `.windsurfrules` exists in this repository, so there is no project-specific rules file from which to extract MUST/SHALL/NEVER clauses.

In their absence I treated the project's own written invariants — statements in `README.md` and in source doc comments that assert how the code behaves — as the equivalent policy surface, since these are the claims the project holds itself to. Each was verified by command output or by driving the real code:

| Rule (source:line) | Status | Evidence |
|---|---|---|
| "an unsupported control request gets an error response rather than silence, so the CLI does not hang" (README.md:179-181) | **Violated** | `client.zig:262,265-266,267` return without answering on a malformed envelope |
| "src/agent.zig ... and src/main.zig ... between them the two roots cover the whole tree" (build.zig:26-27) | **Violated** | `zig test src/main.zig` → "All 0 tests passed."; `demo_tools.zig:63` never executes |
| "`arena` is reset after the result is written" (tool.zig:14-15) | **Violated** | `client.zig:285` resets at the top of dispatch, before the handler runs |
| "`bare` disables skill discovery outright" (README.md:62) | **Violated** | CLI v2.1.228 `--bare` help: "Skills still resolve via /skill-name" |
| "No dependencies beyond the standard library" (README.md:112) | **Met** | `build.zig.zon:6` → `.dependencies = .{}` |
| Layout table lists every source file (README.md:114-123) | **Met** | Table's 8 entries match `ls src/` exactly |
| Usage example reflects the real API (README.md:127-144) | **Met** | Compiles verbatim against current `src/`; `open(gpa, io, opts)` matches `client.zig:52` |
| "stdin must stay open for the whole turn ... call `closeStdin` after the `result` event" (README.md:106-108) | **Met** | `main.zig:79` closes stdin only in the `.result` branch |
| "The `mcp_response` wrapper on tool replies is load-bearing" (README.md:173-175) | **Met** | `protocol.zig:114-133`; pinned by test at `protocol.zig:330` |
| Every source file begins with a `// src/<name>.zig` header | **Met** | All 8 files verified; each header matches its filename |
| `--permission-prompt-tool stdio` routes prompts over the control channel (README.md:176-178) | **Violated** | Flag absent from `claude --help` in CLI v2.1.228 |

---

## Validation Command Output

```
$ zig version
0.16.0

$ claude --version
2.1.228 (Claude Code)

$ zig build
(exit 0, no output)

$ zig build test --summary all
Build Summary: 5/5 steps succeeded; 19/19 tests passed
test success
+- run test 19 pass (19 total) 7ms MaxRSS:3M
|  +- compile test Debug native cached 45ms MaxRSS:35M
+- run test success 3ms MaxRSS:2M
   +- compile test Debug native cached 46ms MaxRSS:35M

$ zig fmt --check build.zig src
(exit 0, no output — all files formatted)

$ zig test src/agent.zig
All 19 tests passed.

$ zig test src/main.zig
All 0 tests passed.          <-- second build.zig test root runs nothing

$ rg 'TODO|FIXME|HACK|XXX' src build.zig justfile README.md
(none)

$ git status --short
(clean)

$ git rev-parse --short HEAD
a93433c

$ git branch --show-current
main

$ git remote -v
origin  https://github.com/cipher-rc5/claude_zig.git (fetch)
origin  https://github.com/cipher-rc5/claude_zig.git (push)

$ ls -R .github
NO .github DIRECTORY — no CI at all

$ cat build.zig.zon | grep dependencies
    .dependencies = .{},

$ ls  (context files)
PRESENT: README.md
missing: LICENSE, CLAUDE.md, AGENTS.md, CONTRIBUTING.md, SECURITY.md,
         CHANGELOG.md, CODE_OF_CONDUCT.md, .editorconfig

--- CLI flag verification against installed binary v2.1.228 ---
OK      --print              OK      --setting-sources
OK      --input-format       OK      --add-dir
OK      --output-format      OK      --plugin-dir
OK      --verbose            OK      --agents
OK      --bare               OK      --disable-slash-commands
OK      --include-partial-messages   OK      --strict-mcp-config
OK      --allowedTools       OK      --mcp-config
OK      --permission-mode    OK      --resume
OK      --append-system-prompt
OK      --tools

--max-turns: absent from --help, but ACCEPTED by the CLI.
Control test proving the CLI does reject unknown flags:
$ claude --print --definitely-not-a-real-flag-xyz 3 "hi"
error: unknown option '--definitely-not-a-real-flag-xyz'
$ claude --print --max-turns 3 "say hi"
Hi! (exit 0)   <-- accepted; undocumented but functional. NOT a defect.

--permission-mode choices accepted by CLI:
"acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"
All five values emitted by options.zig:16-24 are valid.

--- Runtime probes (real Client driven against stub CLIs) ---

[missing binary]
RESULT: open() returned error.FileNotFound      <-- clean, surfaces at open()

[final line WITHOUT trailing newline]
A: kind=system result=-
A: kind=result result=NOTRAILING
A: TOTAL EVENTS = 2 (expect 2)                  <-- no dropped final line

[final line WITH trailing newline]
B: kind=system result=-
B: kind=result result=TRAILING
B: TOTAL EVENTS = 2 (expect 2)                  <-- no spurious empty line

[200 KB single line, 64 KB stdout buffer]
C: kind=system resultlen=0
C: kind=result resultlen=200000
C: TOTAL = 2 (expect 2)                         <-- oversized line handled

[max_line_bytes=1024 vs oversized line — recovery behavior]
call 0: EVENT kind=system sub=a resultlen=0
call 1: error.ProtocolTooLong
call 2: error.ProtocolTooLong
call 3: error.ProtocolTooLong
call 4: error.ProtocolTooLong
call 5: error.ProtocolTooLong                   <-- permanently unrecoverable

[CLI starts then exits non-zero (simulated auth failure)]
simulated CLI startup failure
events seen = 0; loop ended NORMALLY (no error)
close() term = .{ .exited = 7 }                 <-- only signal; README discards it
```
