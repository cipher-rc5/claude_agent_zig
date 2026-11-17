# claude_agent_zig: Agent Rules

These rules apply to every LLM agent and human contributor working in this
repository. This file supersedes any `AGENTS.md` in a parent directory: rules
written for other projects (Bun, TypeScript, Effect, Elysia, Next.js, dprint)
do not apply here.

`CONTRIBUTING.md` and `SECURITY.md` are the detailed sources of truth. This
file summarizes what an agent must not get wrong. Where they disagree, fix the
drift rather than picking one.

---

## What this codebase is

A Claude Agent SDK client for Zig. It drives the Claude Code CLI as a child
process over the bidirectional `stream-json` protocol (newline-delimited JSON
on stdin/stdout) and serves in-process tools to it as SDK MCP servers through
the control protocol.

- Language: Zig, standard library only. No dependencies, no network access at
  build time. Do not add a dependency to `build.zig.zon`.
- Public surface: `src/agent.zig`, exposed by `build.zig` as the module
  `agent`. Everything a caller may touch is re-exported there.
- Runtime dependency: the `claude` CLI, used only for agent requests and
  release compatibility checks. Building and the unit tests do not need it.
- Platform: macOS on Apple Silicon is the supported, validated target. Linux
  is untested and Windows is unsupported. Do not claim support for either.
- Licence: proprietary, all rights reserved. External contributions are not
  accepted without prior written permission.

This repository has no TypeScript, JavaScript application, package manifest,
HTTP service, database, or container tooling. Do not invent typecheck,
frontend, migration, or Docker steps. The only non-Zig code is Python 3.12+
and shell delivery tooling under `scripts/` and `.githooks/`, plus CommonJS
validators inside `.agents/skills/security-audit/`.

---

## Toolchain

- Zig **0.17.1** exactly. `build.zig` rejects any other version. Do not bump
  the pin unless explicitly asked.
- Task runner: `just`. Run `just` with no arguments to list recipes.
- Formatter: `zig fmt`, which is canonical. Never hand-format against it.
- Python tooling uses `python3` (3.12+). Do not add Python packages; the
  scripts use the standard library.

## The gate

`just ci` must pass before a change is considered done:

```
just ci  ->  fmt-check  ->  docs-check  ->  test  ->  test-release  ->  build
```

| Need | Command |
|---|---|
| Format in place | `just fmt` |
| Unit tests (Debug) | `just test` |
| Unit tests (ReleaseSafe) | `just test-release` |
| Confirm new tests ran | `zig build test --summary all` (check each root's count went up) |
| README drift check | `just docs-check` |
| Offline protocol fixtures | `just compatibility` |
| Delivery tooling | `just tooling-test` |
| Extended native checks | `just ci-extended` |
| Release validation | `just ci-full` |

`docs-check` is in the gate because doc-vs-code drift is this repository's
most common defect. It requires the README `## Layout` table to list exactly
the `.zig` files under `src/`, `examples/` and `tests/`, and the README
`## Usage` block to compile against the current `agent` module.

Live model use is never part of a gate. `just compatibility-live` and `just
dev` spend real budget: run them only when the user explicitly asks.

---

## Code conventions

- **File header.** Every Zig source file in `src/`, `examples/`, `tests/` and
  `bench/` begins with a path comment naming itself, then one line on its
  role:

  ```zig
  // src/options.zig
  // Session configuration, and the CLI flags it translates into.
  ```

- **Naming** follows Zig standard style: `camelCase` functions, `snake_case`
  variables, fields and constants, `PascalCase` types. Match the surrounding
  code.
- **Comments** are brief. Document contracts, ownership, lifetimes, threading,
  and non-obvious reasons. Do not narrate routine operations.
- **Public API changes** go through `src/agent.zig`. When the surface
  changes, also update the re-export test in `tests/client_test.zig`, the
  README Layout table and Usage example, and `CHANGELOG.md`.
- **Do not widen the public API for test layout.** Several decls are `pub`
  only so sibling modules can call them (all of `protocol.zig`, `buildArgv`,
  `findServer`). They are internal and stay out of `agent.zig`.
- **No emojis** in source, comments, logs, or documentation.

### Where a test goes

- A test touching only names re-exported by `src/agent.zig` goes in `tests/`
  and reaches the library through the `agent` module.
- A test touching anything else stays in its own module under the
  `// --- tests ---` divider, with a brief comment naming what keeps it there.
- **A new file in `tests/` needs a `_ = @import(...)` line in
  `tests/all.zig`**, or it compiles, reports success, and runs nothing.
- A file belongs to exactly one Zig module, and a test root cannot import
  upward by relative path. The `agent` module is the only route across
  directories.

---

## Safety invariants

Read `SECURITY.md` before changing `src/client.zig`, `src/protocol.zig`,
`src/transport.zig`, or anything that writes to the child's stdin. Preserve:

- **Every correlatable control request gets a reply**, including malformed
  ones; an unanswered request stalls the CLI. The only silent path is a
  request with no usable id.
- **Complete-frame budget.** Every control reply, fallbacks included, renders
  within `max_reply_line_bytes` (16 896 bytes, newline included). Oversized
  content gets a bounded, method-appropriate error or denial. Never truncate a
  correlation id. When even the fallback cannot fit, the session terminates
  with `error.ReplyTooLong`.
- **One line per frame.** Replies are single-line JSON. Raw values spliced via
  `beginWriteRaw` (tool input schemas, permission replacement inputs) are
  validated as JSON objects first and compacted. Never splice an unvalidated,
  caller-supplied string.
- **Stdin ownership.** Replies are written from inside `next()` under the
  write lock. Writes after `closeStdin` are refused with `error.StdinClosed`.
  Do not move reply writing off the caller's thread without revisiting the
  lock and descriptor-reuse reasoning.
- **Handler errors reach the model** as `@errorName` text. OutOfMemory is
  answered to the CLI first, then propagated.
- **Lifetimes.** `Event` is caller-owned; `EventView` is borrowed until the
  next read. Handler results must stay valid through reply writing; the
  scratch arena resets before each dispatch.

---

## MCP protocol

The in-process MCP server is dual-era, as MCP `2026-07-28` permits. The era
is chosen per request with no connection state (`selectEra` in
`src/client.zig`):

- `initialize` selects legacy semantics (`2025-11-25` and earlier). The CLI
  opens this way today. It echoes the offered `protocolVersion`, falling back
  to `default_protocol_version`.
- `params._meta["io.modelcontextprotocol/protocolVersion"] = "2026-07-28"`,
  with a `clientCapabilities` object, selects modern semantics. Results carry
  `resultType` and `_meta["io.modelcontextprotocol/serverInfo"]`. `tools/list`
  and `server/discover` also carry `ttlMs` / `cacheScope`.
- Any other version in `_meta` gets `-32022`, listing
  `supported_protocol_versions`.
- **Legacy replies must stay byte-compatible.** Do not add modern-only fields
  to the handshake path.
- Error codes: `-32601` unknown method or server, `-32602` invalid params,
  unknown tool, or malformed `_meta`, `-32603` internal error, `-32022`
  unsupported protocol version. Do not emit codes from `-32020` to `-32099`
  that the spec does not define.
- Tool failures are results with `isError: true`, not JSON-RPC errors.

The spec is at https://modelcontextprotocol.io/specification/2026-07-28. When
the protocol changes, update `src/protocol.zig` constants, `docs/README.md`
(constants table), `docs/control-protocol.md`, and `docs/wire-protocol.md`
together.

For protocol or CLI-integration changes, the synthetic fixtures (`just
compatibility`) and parser probes (`just canary`) cannot establish current
CLI behaviour. Recommend an opt-in live matrix run before release, but do not
start one without explicit permission.

---

## Documentation

- `docs/` holds internals: architecture, wire schemas, control flow, and
  concurrency. `docs-check` does not cover it. When you change a constant, an
  error set, a wire shape, or the lock order, update the page that covers it,
  including the constants table in `docs/README.md`.
- Note user-visible changes in `CHANGELOG.md` under `## [Unreleased]` (Keep a
  Changelog format).

## Private material

- `_dev/` is git-ignored internal material (reviews, evidence, benchmarks). It
  must never reach Git. Do not `git add -f` it or move its contents into a
  tracked path. `.zig-cache/`, `zig-out/` and `dist/` are ignored too.
- Check with `git check-ignore -v <path>` before assuming a path is ignored.
- Repository skills live in `.agents/skills/`: `cipher-review` for
  production-readiness reviews, `security-audit` for security work, and
  `git-c-all` for commit and push. Follow them when their task applies.
  Editing a skill does not authorize running its workflow.

---

## Git and commits

- Commit or push only when asked. A commit request does not authorize a push.
- Conventional Commits, matching history:
  `<type>[optional scope]: <imperative summary>`, subject at most 72
  characters. Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`,
  `test`, `build`, `ci`, `chore`, `revert`. Useful scopes: `client`,
  `protocol`, `transport`, `options`, `tools`, `tests`, `docs`, `release`.
- No AI-author credits, generated-by claims, or co-author trailers.
- `just fmt-check` and `just docs-check` must pass before committing, and
  `just ci` before pushing. Hooks under `.githooks/` enforce this once
  installed (`just hooks-install`). Do not install or bypass them without
  explicit instruction.
- `just release <version>` builds `dist/` but never tags, commits, or pushes.
  Tagging is the owner's decision.
