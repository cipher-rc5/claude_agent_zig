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

Zig **0.16.0** exactly. `build.zig.zon` sets `.minimum_zig_version = "0.16.0"`,
and the codebase uses 0.16 APIs (the new `Io` interface, `std.json.Stringify`,
`std.process.spawn`) that do not compile on 0.15 or earlier.

The library has no dependencies beyond the standard library, and nothing should
be added. `zig build` needs no network access.

The `claude` CLI is a *runtime* dependency, needed only to actually talk to an
agent (`just dev`). Building and testing do not require it. Check both
toolchains with:

```
just versions
```

## The gate

`just ci` is the pre-commit and pre-push gate. It runs, in order:

```
just ci   ->  fmt-check  ->  docs-check  ->  test  ->  build
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

Run it before every commit. A git **pre-push hook** enforces the same thing, so
a push whose tree does not pass `just ci` is rejected before it leaves your
machine. Install the hook once per clone:

```
just hooks-install
```

The hook lives under `.githooks/` and is wired up by pointing `core.hooksPath`
at that directory, so it is version-controlled alongside the code rather than
hidden in `.git/hooks/`.

The hook validates the **working tree**, while git is pushing specific commits.
Those coincide only when you are pushing `HEAD` with a clean tree. It reads the
refs git passes on stdin and prints a warning when they diverge — pushing a
non-`HEAD` commit, or pushing with uncommitted changes — so a green gate is not
mistaken for a verdict on the commits actually leaving the machine. The warning
does not block: pushing a side branch is legitimate, and failing there would
force `--no-verify`, which also skips the CI run that matters.

## Recipes

`just` with no arguments lists everything. The full set:

| Recipe | What it does |
|---|---|
| `just build` | `zig build` — executable into `zig-out/bin/`. |
| `just test` | `zig build test` — unit tests across all modules. |
| `just check` | Build and test with a full `--summary all` step breakdown. |
| `just fmt` | `zig fmt build.zig src examples tests` — formats in place. |
| `just fmt-check` | Fails if anything is unformatted. Used by `ci`. |
| `just docs-check` | Fails if the README has drifted from the code. Used by `ci`. |
| `just ci` | `fmt-check` + `docs-check` + `test` + `build`. The gate. |
| `just dev "<prompt>"` | Build and run one turn against the agent. |
| `just dev-release "<prompt>"` | Same, `-Doptimize=ReleaseFast`. |
| `just clean` | Removes `zig-out/` and `.zig-cache/`. |
| `just versions` | Prints the `zig` and `claude` versions in use. |
| `just hooks-install` | Points `core.hooksPath` at `.githooks/`. |
| `just hooks-uninstall` | Clears `core.hooksPath`, disabling the gate. |
| `just canary` | Checks the installed CLI still accepts every flag and permission mode this client emits. |
| `just ci-full` | `ci` plus `canary`. Run before a release or after a CLI upgrade. |

`canary` is worth knowing about: the Claude Code CLI is versioned independently
of this library, so an upgrade can silently break the wire protocol. It probes
the CLI's `--help` for each flag `buildArgv` generates and exits 0 with a SKIP
when the CLI is not on `PATH`, so it is safe to run anywhere. It is not part of
`ci` — run it after upgrading the CLI.

Two details of how it matches matter, because both were once wrong:

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

Two environment variables are honoured: `CLAUDE_BIN` (path to the CLI, default
`claude`) and `AGENT_SKILLS` (comma list restricting invocable skills; unset
means all).

## What is not published

`_dev/` holds internal working material — code reviews enumerating this
codebase's weaknesses, and similar notes. It is **git-ignored and untracked**:
this is a proprietary all-rights-reserved project, and that material must not
reach the public repository.

The directory stays on your disk; it is only absent from git. If you add
anything under `_dev/`, leave it there — do not `git add -f` it, and do not
move internal notes into a tracked path.

`.gitignore` covers `.zig-cache/`, `zig-out/` and `_dev/`. Confirm a path is
ignored before assuming it is:

```
git check-ignore -v _dev
```

## Conventions

**Formatting is `zig fmt`, and it is canonical.** Do not hand-format against
it, and do not argue with its output — `just fmt-check` is part of `ci`, so
unformatted code cannot be committed.

**Every source file begins with a path comment naming itself**, followed by a
short line describing the file's role. This holds in `src/`, `examples/`, and
`tests/` alike:

```zig
// src/options.zig
// Session configuration, and the CLI flags it translates into.
```

New source files must follow this. It is how the layout table in the README
stays checkable against the tree.

### Where a test goes

The repo is three directories by role: `src/` is the library, `examples/` is
the demo, `tests/` is the black-box suite.

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
`protocol.zig`) yet are deliberately absent from `agent.zig`. Those are
internal, so their tests stay put too.

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
layout table and usage example in sync when that surface changes.

## Commits

Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, …),
matching the existing history. Keep the subject in the imperative mood.

Note user-visible changes in `CHANGELOG.md` under `## [Unreleased]`.
