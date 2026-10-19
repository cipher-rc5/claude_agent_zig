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

Zig **0.17.0** exactly. `build.zig` checks the version declared in
`build.zig.zon` and rejects other toolchains before building. The manifest's
minimum alone would also accept newer, potentially incompatible versions.

The library has no dependencies beyond the standard library, and nothing should
be added. `zig build` needs no network access. Local delivery tooling requires
Python 3.12 or newer, a Bourne shell, `just`, and standard Git/SSH tools.

The `claude` CLI is a runtime dependency for agent requests (`just dev`) and
a required parser-compatibility check for releases. Building, unit tests, and
the extended offline gate do not require it. Check both
toolchains with:

```
just versions
```

macOS on Apple Silicon is the supported platform. Linux is untested and
outside the validation scope; Windows is unsupported. See README Platforms.

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

`test-release` runs the suite under `ReleaseSafe`. `just ci-extended` also
runs ReleaseFast, compiles complete examples, generates API docs, exercises
offline protocol and delivery fixtures, checks shell syntax, runs benchmark
and argument-forwarding smoke checks on macOS. Each command has an
independent process supervisor deadline. Platform claims require native
runtime evidence; sharing POSIX APIs does not establish another OS's behavior.

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
- **`pre-push`** gates each distinct pushed ref tip in a temporary detached
  worktree, using that tip's `justfile` and sharing the main tree's Zig cache.
  It tests tips, not every intermediate commit in a pushed range. Ref deletes
  are skipped; checkout failures block the push. Worktrees are removed on
  success, failure, or interruption. `git push --no-verify` bypasses the
  repository's local push gate. There is no remote enforcement.

## Recipes

`just` with no arguments lists everything. The full set:

| Recipe | What it does |
|---|---|
| `just build` | `zig build` — executable into `zig-out/bin/`. |
| `just test` | `zig build test` — unit tests across all modules. |
| `just test-release` | `zig build test -Doptimize=ReleaseSafe`. Used by `ci`. |
| `just check` | Build and test with a full `--summary all` step breakdown. |
| `just fmt` | `zig fmt build.zig src examples tests bench scripts` — formats in place. |
| `just fmt-check` | Fails if anything is unformatted. Used by `ci`. |
| `just docs-check` | Fails if the README has drifted from the code. Used by `ci`. |
| `just ci` | `fmt-check` + `docs-check` + `test` + `test-release` + `build`. The gate. |
| `just dev "<prompt>"` | Build and run one turn against the agent. |
| `just dev-release "<prompt>"` | Same, `-Doptimize=ReleaseFast`. |
| `just bench [lines] [workload] [runs]` | Real-pipe ReleaseFast benchmark; defaults to 20 000 normal deltas and one run. |
| `zig build examples-check` | Compiles streaming, permission, initialization, and shutdown programs without running them. |
| `just docs` | `zig build docs` — autodocs for the `agent` module into `zig-out/docs/`. |
| `just clean` | Removes `zig-out/` and `.zig-cache/`. |
| `just versions` | Prints the `zig` and `claude` versions in use. |
| `just hooks-install` | Points `core.hooksPath` at `.githooks/` (both hooks). |
| `just hooks-uninstall` | Clears `core.hooksPath`, disabling the gate. |
| `just canary` | Checks the installed CLI meets `min_cli_version` and still accepts every flag and permission mode this client emits. |
| `just canary-strict` | Fails if the CLI is missing, incompatible, or its parser probes are inconclusive. |
| `just compatibility` | Public-client tests against a synthetic offline protocol fixture. |
| `just compatibility-live PATH` | Opt-in live protocol matrix with bounded CLI sessions, deadlines, and sanitized evidence; never part of a gate. |
| `just tooling-test` | Offline canary, artifact, signer, supervisor, and hook fixtures. |
| `just runtime-validate PATH` | Fresh macOS test matrix, 100 stress runs per group, generated fuzz, and strict parser checks; writes evidence to a new ignored directory. |
| `just ci-extended` | Supervised native macOS checks. |
| `just ci-full` | `ci-extended` plus `canary-strict`; required for release validation. |
| `just canary-schedule-install` | Runs `canary` weekly: a launchd agent on macOS, a printed crontab line elsewhere. |
| `just canary-schedule-uninstall` | Removes that schedule. |
| `just release <version>` | Cuts `dist/` for a version: tarball, `SHA256SUMS`, CycloneDX SBOM, optional ssh signature. Never tags, commits, or pushes. |
| `just release-verify <version>` | Validates every archive entry, exact source membership, checksums, SBOM metadata, optional signer trust, and an isolated package consumer. |

`canary` checks the installed CLI's version, advertised flags, permission
modes, and parser-only probes for unadvertised flags. A sentinel unknown
option ensures a probe reached argument parsing; unrelated execution failure
cannot count as flag acceptance. Version, timeout, and inconclusive-probe
failures are errors. The developer recipe skips a missing binary; the strict
recipe fails. Neither submits a model request. The flag list is maintained
in `scripts/canary.py`; update it when `buildArgv` emits another flag. Modes
and the version floor are derived from `src/options.zig`.

`compatibility` exercises initialization, MCP list/call, permission allow/deny,
interrupt, and resume against a hand-authored synthetic fixture. It is not a
recorded transcript of the current CLI. Live behavioral verification requires
an explicit opt-in run in a controlled workspace with resource and cost limits.
`just compatibility-live PATH` explicitly permits the live matrix in temporary
workspaces using harmless SDK tools, empty built-in tools, and disabled
settings/skills/hooks. Seven isolated scenarios cover MCP registration/list/call,
permission allow/deny/replacement, interruption, rejection, and resumed sessions.
One rejection case deliberately changes an interrupt subtype; that test does
not represent rejection of a valid interrupt. The interruption case requires
observed stream progress followed by curtailed output and a correlated
acknowledgement; a canceled terminal result is recorded as cancellation.
Defaults allow eight CLI clients
and twelve configured model turns, with USD 0.05 per-client budget thresholds
(USD 0.40 aggregate) and a 60-second process deadline per scenario. These are
CLI thresholds, not billing guarantees or exact API-request limits. The script
requires `--allow-model-use`, preserves sanitized evidence, and removes only
session artifacts associated with fresh UUIDs it generated. No live model
request is part of either local gate.

For protocol or CLI-integration changes, run the opt-in live matrix before
publishing the corresponding release. Retain evidence matching the SDK source
and CLI version being released. Parser probes and synthetic fixtures cannot
establish current CLI control-envelope behavior. Keep live model use manual
with the matrix's budget thresholds and process deadlines.

`release` is the other recipe with rules. It refuses a dirty tree, a version
that does not match `build.zig.zon`'s `.version`, a version `CHANGELOG.md` has
no `## [<version>]` heading for, and a `v<version>` tag that points somewhere
other than `HEAD`; then it runs `just ci-full` and writes `dist/`. It ends by
printing the `git tag -a` command and stops. Tagging and pushing the tag are
the owner's decision, made after looking at what is in `dist/`. The signature
is an `ssh-keygen -Y sign` over `SHA256SUMS`, produced only when
`RELEASE_SIGNING_KEY` names a private key, and `release-verify` checks it only
when `RELEASE_ALLOWED_SIGNERS` names an `allowed_signers` file; without that it
reports integrity-only verification. Set `RELEASE_ALLOWED_SIGNERS`, or run
`bash scripts/release-verify.sh <version> --require-signature`, when
authentication is required. `release-verify` uses
the trusted local `HEAD` by default; `--commit <full-sha>` selects another
trusted local commit for exact archive and metadata comparison.

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

Complete each audit with both `critical_analysis_<YYYYMMDD_HHMMSS>.md` and
`improvements_<YYYYMMDD_HHMMSS>.md` under `_dev/reviews/`, using the
`codebase-audit` skill's report and checklist templates. Preserve prior runs,
state the score's rubric, and leave unverified tasks open.

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

Keep comments brief. Document contracts, constraints, and non-obvious reasons;
let names and assertions explain routine operations. Preserve public ownership,
threading, lifetime, and failure guarantees when shortening API documentation.

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
executable examples, `tests/` is the black-box suite. (`bench/` is tooling, not a role;
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

## Performance evidence

Run `zig build bench -Doptimize=ReleaseFast -- 20000 all 5` on a quiet machine.
Record the exact compiler, OS/architecture, hardware, workload, repetitions,
and concurrent load with the JSONL results. Report medians and dispersion;
one smoke run is not a baseline. Workloads cover normal/escaped deltas,
8 KiB deltas, MCP tool dispatch, and a 2 MiB event followed by small events.

Metrics include throughput, per-event p50/p95/p99/max latency, successful
backing allocations and allocated growth bytes per returned event, and
peak/retained SDK-owned memory. Event ownership and cleanup are included;
startup, transcript creation, and harness timing storage are excluded.
Investigate repeatable regressions above 10% in median throughput or allocated
bytes/event on an identical workload. Recheck noisy timing before deciding a
change regressed. Safety fixes may justify a measured cost. Keep internal
benchmark/review evidence under ignored `_dev/`.

For comparisons, compile the same metadata-bearing benchmark harness against
each SDK snapshot in ReleaseFast, then run `scripts/bench_compare.py` with
explicit `--before`, `--after`, `--before-source`, `--after-source`, `--seed`,
and a new ignored `--output` directory. Defaults use 20 measured pairs and
three warmup pairs per workload. The schedule balances and randomizes order;
warmups are excluded from summaries. Preserve raw samples and bootstrap
intervals, and check host load before drawing timing conclusions. Recorded
source hashes identify supplied inputs; they do not independently prove which
sources produced an executable.

## Commits

Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, …),
matching the existing history. Keep the subject in the imperative mood.

Note user-visible changes in `CHANGELOG.md` under `## [Unreleased]`. The
`release` recipe refuses a version this file has no heading for, so the notes
have to be moved under one before a release can be cut.
