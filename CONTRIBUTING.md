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
just ci   ->  fmt-check  ->  test  ->  build
```

Run it before every commit. A git **pre-push hook** enforces the same thing, so
a push whose tree does not pass `just ci` is rejected before it leaves your
machine. Install the hook once per clone:

```
just hooks-install
```

The hook lives under `.githooks/` and is wired up by pointing `core.hooksPath`
at that directory, so it is version-controlled alongside the code rather than
hidden in `.git/hooks/`.

## Recipes

`just` with no arguments lists everything. The full set:

| Recipe | What it does |
|---|---|
| `just build` | `zig build` — executable into `zig-out/bin/`. |
| `just test` | `zig build test` — unit tests across all modules. |
| `just check` | Build and test with a full `--summary all` step breakdown. |
| `just fmt` | `zig fmt build.zig src` — formats in place. |
| `just fmt-check` | Fails if anything is unformatted. Used by `ci`. |
| `just ci` | `fmt-check` + `test` + `build`. The gate. |
| `just dev "<prompt>"` | Build and run one turn against the agent. |
| `just dev-release "<prompt>"` | Same, `-Doptimize=ReleaseFast`. |
| `just clean` | Removes `zig-out/` and `.zig-cache/`. |
| `just versions` | Prints the `zig` and `claude` versions in use. |
| `just hooks-install` | Points `core.hooksPath` at `.githooks/`. |
| `just hooks-uninstall` | Clears `core.hooksPath`, disabling the gate. |
| `just canary` | Checks the installed CLI still accepts every flag and permission mode this client emits. |

`canary` is worth knowing about: the Claude Code CLI is versioned independently
of this library, so an upgrade can silently break the wire protocol. It probes
the CLI's `--help` for each flag `buildArgv` generates and exits 0 with a SKIP
when the CLI is not on `PATH`, so it is safe to run anywhere. It is not part of
`ci` — run it after upgrading the CLI.

Two environment variables are honoured: `CLAUDE_BIN` (path to the CLI, default
`claude`) and `AGENT_SKILLS` (comma list restricting invocable skills; unset
means all).

## Conventions

**Formatting is `zig fmt`, and it is canonical.** Do not hand-format against
it, and do not argue with its output — `just fmt-check` is part of `ci`, so
unformatted code cannot be committed.

**Every file under `src/` begins with a path comment naming itself**, followed
by a short line describing the file's role:

```zig
// src/options.zig
// Session configuration, and the CLI flags it translates into.
```

New source files must follow this. It is how the layout table in the README
stays checkable against the tree.

**Tests live beside the code they cover**, at the bottom of the module, after a
`// --- tests ---` divider where the file has one.

Be careful here: Zig only runs tests it can *reach* from a test root's import
graph. A plain `const x = @import("foo.zig")` does not pull in `foo.zig`'s
`test` blocks — only an explicit `_ = @import("foo.zig")` or a `refAllDecls`
reference does. A module that is imported but not referenced that way is
silently untested, and the summary still prints a reassuring pass line.

So after adding tests, confirm they actually ran. `just test` prints the count;
if your new tests are not in it, they are not being executed:

```
zig build test --summary all      # check the reported test count went up
```

**Public API changes go through `src/agent.zig`**, which is the single public
surface and re-exports everything callers should touch. Keep the README's
layout table and usage example in sync when that surface changes.

## Commits

Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, …),
matching the existing history. Keep the subject in the imperative mood.

Note user-visible changes in `CHANGELOG.md` under `## [Unreleased]`.
