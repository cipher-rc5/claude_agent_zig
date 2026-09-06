# Contributing

## Licensing, first

This is proprietary, all-rights-reserved software. See [LICENSE](LICENSE).

External contributions are **not** accepted by default. Do not open a pull
request without prior written permission from the copyright holder
([@cipher-rc5](https://github.com/cipher-rc5)). Submitting code without that
permission does not grant anyone a licence to it, and it cannot be merged.

If you have found a security issue, do not open a public issue or PR — follow
[SECURITY.md](SECURITY.md) instead.

## Toolchain

Zig **0.16.0** exactly, and `build.zig` enforces it: a comptime check compares
`builtin.zig_version` with the `.minimum_zig_version` that `build.zig.zon`
declares and refuses any other version, naming both. The manifest field is
only a floor by itself, and a later toolchain would otherwise be accepted
there and fail somewhere inside `std` instead of at the first line of the
build. The codebase uses 0.16 APIs (the new `Io` interface,
`std.json.Stringify`, `std.process.spawn`) that do not compile on 0.15 or
earlier, and it is tested on exactly one toolchain.

The library has no dependencies beyond the standard library, and nothing should
be added. `zig build` needs no network access.

The `claude` CLI is a *runtime* dependency, needed only to actually talk to an
agent (`just dev`). Building and testing do not require it. Check both
toolchains with:

```
just versions
```

macOS and Linux are the supported platforms; see the README's Platforms
section for why Windows is not.

## The gate

`just ci` is the gate. It runs, in order:

```
just ci   ->  fmt-check  ->  docs-check  ->  test  ->  test-release  ->  build
```

`docs-check` is there because doc-vs-code drift, not compile failure, is this
repo's most common defect. `fmt-check`, `test` and `build` are all blind to it.
It runs `scripts/docs-check.sh`, which checks two things mechanically:

- the README `## Layout` table lists **exactly** the `.zig` files present under
  `src/`, `examples/` and `tests/` — a missing row and a stale row both fail;
- the README's `## Usage` ```zig block still **compiles** against the current
  `agent` module. The block is wrapped in a `main()` and handed to
  `zig build-exe`; a renamed field or a changed signature fails the build.

It is offline, needs no `claude` binary, runs nothing it compiles, and takes
about a second. When it fails it prints the compiler error and points at the
README line — it never edits the README for you.

`test-release` runs the suite under `ReleaseSafe`. The client reasons about
release modes explicitly — asserts that vanish under `ReleaseFast`, safety
checks that stay under `ReleaseSafe` — so a gate that ran Debug alone would
never exercise the modes the code is written around.

Two git hooks enforce the gate, and CI is strictly local: there is no hosted
workflow, by decision. Install the hooks once per clone:

```
just hooks-install
```

They live under `.githooks/` and are wired up by pointing `core.hooksPath` at
that directory, so they are version-controlled alongside the code rather than
hidden in `.git/hooks/`. `just hooks-uninstall` clears the setting.

- **`pre-commit`** runs the fast half, `fmt-check` and `docs-check`, on the
  working tree — what the editor just saved is what `zig fmt` and the drift
  check need on disk. It fails closed without `zig` or the script. Bypass one
  commit with `git commit --no-verify`; the push gate still runs on it.
- **`pre-push`** gates the **commits being pushed**, not the working tree.
  For each non-zero local sha git names on stdin it checks that commit out
  detached into a temporary worktree, runs `just ci` there with that commit's
  own `justfile` (or the same steps by hand when `just` is absent), and
  removes the worktree on every exit path, including a failure or an
  interrupt. A dirty tree or a pushed side branch therefore cannot make a
  green result mean anything other than "this commit passes". Two refs at the
  same commit are gated once; a ref delete is skipped with a note; a sha that
  cannot be checked out blocks the push rather than passing. The worktree
  shares the main tree's `.zig-cache`, so the two optimize modes are
  incremental rather than a cold rebuild. Bypass with `git push --no-verify`,
  which skips the only CI this repository has.

## Recipes

`just` with no arguments lists everything. The full set:

| Recipe | What it does |
|---|---|
| `just build` | `zig build` — executable into `zig-out/bin/`. |
| `just test` | `zig build test` — unit tests across all modules. |
| `just test-release` | `zig build test -Doptimize=ReleaseSafe`. Used by `ci`. |
| `just check` | Build and test with a full `--summary all` step breakdown. |
| `just fmt` | `zig fmt build.zig src examples tests bench` — formats in place. |
| `just fmt-check` | Fails if anything is unformatted. Used by `ci`. |
| `just docs-check` | Fails if the README has drifted from the code. Used by `ci`. |
| `just ci` | `fmt-check` + `docs-check` + `test` + `test-release` + `build`. The gate. |
| `just dev "<prompt>"` | Build and run one turn against the agent. |
| `just dev-release "<prompt>"` | Same, `-Doptimize=ReleaseFast`. |
| `just bench [lines]` | `zig build bench -Doptimize=ReleaseFast`: `Client.next()` over a synthetic `stream_event` transcript (default 20 000 lines). |
| `just docs` | `zig build docs` — autodocs for the `agent` module into `zig-out/docs/`. |
| `just clean` | Removes `zig-out/` and `.zig-cache/`. |
| `just versions` | Prints the `zig` and `claude` versions in use. |
| `just hooks-install` | Points `core.hooksPath` at `.githooks/` (both hooks). |
| `just hooks-uninstall` | Clears `core.hooksPath`, disabling the gate. |
| `just canary` | Checks the installed CLI meets `min_cli_version` and still accepts every flag and permission mode this client emits. |
| `just ci-full` | `ci` plus `canary`. Run before a release or after a CLI upgrade. |
| `just canary-schedule-install` | Runs `canary` weekly: a launchd agent on macOS, a printed crontab line elsewhere. |
| `just canary-schedule-uninstall` | Removes that schedule. |
| `just release <version>` | Cuts `dist/` for a version: tarball, `SHA256SUMS`, CycloneDX SBOM, optional ssh signature. Never tags, commits, or pushes. |
| `just release-verify <version>` | Checks what `release` left in `dist/`: sums, archive prefix, SBOM, and the signature when configured. |

`canary` is worth knowing about: the Claude Code CLI is versioned independently
of this library, so an upgrade can silently break the wire protocol. It probes
the CLI's `--help` for each flag `buildArgv` generates, `--permission-prompts`
included, probes the two flags `--help` omits (`--max-turns` and
`--permission-prompt-tool`) by rejection, checks the installed version against
the floor, and exits 0 with a
SKIP when the CLI is not on `PATH`, so it is safe to run anywhere. It is not
part of `ci` — run it after upgrading the CLI, or let
`canary-schedule-install` run it weekly.

Three details of how it matches matter, because the first two were once wrong:

- Flag names are matched **anchored** on a word boundary, not as substrings. An
  unanchored match reports `ok --add-dir` against a CLI that has renamed the
  flag to `--add-dirs`, which is precisely the drift the canary exists to catch.
- The permission-mode list is **derived from `src/options.zig`** by parsing the
  wire names out of `cliName()`, rather than being repeated in the justfile. A
  hardcoded copy drifts silently when a mode is added, and the mode that went
  missing was `bypassPermissions` — the one that disables every permission
  check. If `cliName()` stops being a flat `.tag => "wireName",` switch, the
  parse yields nothing and the canary fails rather than passing on an empty
  list.
- The version floor is likewise parsed out of `src/options.zig`, from the
  line `pub const min_cli_version = "X.Y.Z";` at column 0, and compared with
  `sort -V`. An empty parse is a failure, not a pass: a renamed or reformatted
  declaration must not silently lift the floor. Nothing probes the version at
  `open`, since `--version` would cost a spawn per session to learn something
  that does not change between sessions.

The flag list itself is hardcoded in the justfile, unlike the modes. A flag
added to `buildArgv` must be added there by hand.

`release` is the other recipe with rules. It refuses a dirty tree, a version
that does not match `build.zig.zon`'s `.version`, a version `CHANGELOG.md` has
no `## [<version>]` heading for, and a `v<version>` tag that points somewhere
other than `HEAD`; then it runs `just ci-full` and writes `dist/`. It ends by
printing the `git tag -a` command and stops. Tagging and pushing the tag are
the owner's decision, made after looking at what is in `dist/`. The signature
is an `ssh-keygen -Y sign` over `SHA256SUMS`, produced only when
`RELEASE_SIGNING_KEY` names a private key, and `release-verify` checks it only
when `RELEASE_ALLOWED_SIGNERS` names an `allowed_signers` file; without that it
says the signature was not checked rather than implying it was.

Environment variables honoured: `CLAUDE_BIN` (path to the CLI, default
`claude`), `AGENT_SKILLS` (comma list restricting invocable skills; unset means
all, empty means none), `AGENT_PERMISSIONS` (`host` routes permission prompts
to the demo's log-and-allow handler), `RELEASE_SIGNING_KEY` (ssh private key;
`release` signs when set), `RELEASE_ALLOWED_SIGNERS` (`release-verify` checks
the signature when set), and `RELEASE_SIGNER_IDENTITY` (optional principal
override; defaults to the first in the file).

## What is not published

`_dev/` holds internal working material — code reviews enumerating this
codebase's weaknesses, and similar notes. It is **git-ignored and untracked**:
this is a proprietary all-rights-reserved project, and that material must not
reach the public repository.

The directory stays on your disk; it is only absent from git. If you add
anything under `_dev/`, leave it there — do not `git add -f` it, and do not
move internal notes into a tracked path.

`.gitignore` covers `.zig-cache/`, `zig-out/`, `dist/` and `_dev/`. Confirm a
path is ignored before assuming it is:

```
git check-ignore -v _dev
```

`bench/`, `scripts/`, `.githooks/` and the `justfile` are tracked but are not
part of the package: `build.zig.zon`'s `.paths` lists `src`, `examples`,
`tests`, the build files and the documents, and nothing else.

## Conventions

**Formatting is `zig fmt`, and it is canonical.** Do not hand-format against
it, and do not argue with its output — `just fmt-check` is part of `ci`, so
unformatted code cannot be committed.

**Every source file begins with a path comment naming itself**, followed by a
short line describing the file's role. This holds in `src/`, `examples/`,
`tests/` and `bench/` alike:

```zig
// src/options.zig
// Session configuration, and the CLI flags it translates into.
```

New source files must follow this. It is how the layout table in the README
stays checkable against the tree.

### Where a test goes

The repo is three directories by role: `src/` is the library, `examples/` is
the demo, `tests/` is the black-box suite. (`bench/` is tooling, not a role;
it carries no tests.)

**The rule for a new test is what it needs to touch.**

- Touches only names re-exported by `src/agent.zig` → it goes in `tests/`, as
  a black-box test, reaching the library through the `agent` module.
- Touches anything else — a private function, a private field, a private test
  helper, or a `pub` decl that `agent.zig` does not re-export → it stays in
  its own module, under the `// --- tests ---` divider, with a brief comment
  saying which name keeps it there.

That second case is not a stylistic preference. Zig cannot expose a private
decl to another file without making it public, and the public API is not
widened for test layout. Note the subtlety in the last clause: several decls
are `pub` so a sibling module can call them (`buildArgv`, `findServer`, all of
`protocol.zig`, `writePermissionAllow` and `writePermissionDeny` among it) yet
are deliberately absent from `agent.zig`. Those are internal, so their tests
stay put too.

The re-exported surface is what `tests/client_test.zig` pins, and it grew:
`PermissionHandler`, `PermissionDecision`, `min_cli_version`,
`ReadError.ControlRequestRejected`, and `OpenError.InvalidToolSchema` are all
public, so a test that needs only those belongs in `tests/`. A test that reaches
`servePermissionRequest` or `noteControlResponse` directly, or that sets the
test-only `reply_override` seam, stays in `src/client.zig`.

Two Zig rules make this a hard boundary rather than a soft one:

- **A file belongs to exactly one module.** `protocol.zig` cannot become its
  own module while `agent.zig` also imports it — the compiler rejects it with
  "files must belong to only one module".
- **A root cannot import upward out of its module path.** A file in `tests/`
  writing `@import("../src/protocol.zig")` fails with "import of file outside
  module path". The `agent` module is the only route across directories.

### Test discovery

Zig only runs tests it can *reach* from a test root's import graph. A plain
`const x = @import("foo.zig")` does not pull in `foo.zig`'s `test` blocks —
only an explicit `_ = @import("foo.zig")` or a `refAllDecls` reference does. A
module imported but not referenced that way is silently untested, and the
summary still prints a reassuring pass line.

`build.zig` therefore names three test roots, and each one earns its coverage
with an explicit `_ =`:

| Root | Reaches |
|---|---|
| `src/agent.zig` | The library. Its `test` block `_ =`s every module. |
| `tests/all.zig` | The black-box suite. Lists each `*_test.zig` with `_ =`. |
| `examples/demo.zig` | The demo. Its `test` block `_ =`s `demo_tools.zig`. |

**Adding a file to `tests/` means adding a line to `tests/all.zig`.** Without
it the file compiles, reports success, and runs nothing.

After adding tests, confirm they actually ran:

```
zig build test --summary all      # check the reported test count went up
```

Read that summary per root, not just the total. A root whose count did not
move is the signal that an `_ =` is missing.

One caveat on comparing totals across a refactor: a test compiled into two
roots runs twice and is counted twice. Before the `agent` module existed the
demo root imported the library by relative path, so the whole library suite
was compiled into both roots and the reported total was almost double the
number of distinct tests. Count distinct tests, not summary lines.

**Public API changes go through `src/agent.zig`**, which is the single public
surface and re-exports everything callers should touch. Keep the README's
layout table and usage example in sync when that surface changes, and add the
new name to the re-export test in `tests/client_test.zig`.

## Commits

Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, …),
matching the existing history. Keep the subject in the imperative mood.

Note user-visible changes in `CHANGELOG.md` under `## [Unreleased]`. The
`release` recipe refuses a version this file has no heading for, so the notes
have to be moved under one before a release can be cut.
