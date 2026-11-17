# Build, test and delivery tooling

All CI is local by design: there is no hosted workflow. The gate is a set of
`just` recipes, enforced by version-controlled git hooks in `.githooks/`.

## Toolchain

| Requirement | Version | Enforced by |
|---|---|---|
| Zig | 0.17.1 exactly | `comptime` check in `build.zig` against `build.zig.zon` `.minimum_zig_version` |
| `claude` CLI | At least `2.1.228` (`min_cli_version`) | `just canary` / `just canary-strict`, not `Client.open` |
| Python | 3.12 or newer | Delivery tooling under `scripts/` |
| `just`, `/bin/sh`, git, ssh-keygen | any | Recipes, hooks, integration stubs, release signing |

The library itself has no dependencies, and `zig build` needs no network.

## Build graph

`build.zig` defines one shared module, `agent` (root `src/agent.zig`), and
every other root imports it. A Zig file belongs to exactly one module, and a
root cannot import a file above its own directory, so the shared module is
the only way to reach the library from another directory.

```mermaid
flowchart TD
    zon["build.zig.zon<br/>version 0.1.0, zig 0.17.1"] -. "comptime version guard" .-> build["build.zig"]
    build --> agent["module agent<br/>src/agent.zig"]

    agent --> demo["exe claude_agent<br/>examples/demo.zig"]
    agent --> ex["examples-check<br/>streaming, permissions,<br/>initialization, shutdown"]
    agent --> t2["test root tests/all.zig"]
    agent --> t3["test root examples/demo.zig"]
    build --> t1["test root src/agent.zig"]
    agent --> bench["exe next_bench<br/>bench/next_bench.zig"]
    agent --> docs["object agent, emitted docs"]

    demo --> S1(["zig build / zig build run"])
    ex --> S2(["zig build examples-check"])
    t1 --> S3(["zig build test / test-compile"])
    t2 --> S3
    t3 --> S3
    bench --> S4(["zig build bench"])
    docs --> S5(["zig build docs into zig-out/docs"])
```

| Step | What it does |
|---|---|
| `zig build` | Installs the demo executable `claude_agent`. |
| `zig build run -- "<prompt>"` | Runs one demo turn. |
| `zig build test` | Runs the three test roots. Accepts `-Dtest-filter=<substr>`. |
| `zig build test-compile` | Compiles the test roots without running them. |
| `zig build examples-check` | Compiles the four complete examples without running them. |
| `zig build -Doptimize=ReleaseFast -Dstrip=true` | Compact release demo; stripping applies to both modules. |
| `zig build bench -- <lines> <workload> <runs> [owned\|view]` | Real-pipe benchmark of either read API. |
| `zig build docs` | Autodocs for the `agent` module. |

## Test roots and discovery

Zig only runs tests it can reach from a root through an explicit `_ =`
reference or `refAllDecls`. A plain `const x = @import(...)` does not run
that file's tests.

```mermaid
flowchart LR
    subgraph R1["root: src/agent.zig"]
        A["test { refAllDecls; _ = each module }"] --> M1["options.zig tests"]
        A --> M2["event.zig"]
        A --> M3["tool.zig tests"]
        A --> M4["protocol.zig tests"]
        A --> M5["transport.zig tests"]
        A --> M6["client.zig tests"]
    end
    subgraph R2["root: tests/all.zig"]
        B["test { _ = each file }"] --> T1["client_test.zig"]
        B --> T2["event_test.zig"]
        B --> T3["integration_test.zig"]
        B --> T4["options_test.zig"]
        B --> T5["tool_test.zig"]
        B --> T6["transport_contract_test.zig"]
    end
    subgraph R3["root: examples/demo.zig"]
        C["test { _ = demo_tools }"] --> D1["demo_tools.zig tests"]
    end
```

Where a test belongs depends on what it touches:

```mermaid
flowchart TD
    Q{"Does the test touch only names<br/>re-exported by src/agent.zig?"}
    Q -- yes --> BB["tests/*.zig: black-box,<br/>through the agent module.<br/>Add the file to tests/all.zig"]
    Q -- no --> IN["Same source file, under<br/>// --- tests ---,<br/>with a comment naming the private decl"]
```

`tests/integration_test.zig` runs the real client against scripted `/bin/sh`
stub CLIs over real pipes, covering lifecycle, tool calls, permission
decisions and framing. The stub is written to a temporary directory and
started by absolute path.

## Gates

```mermaid
flowchart TD
    subgraph CI["just ci (the gate)"]
        direction LR
        F["fmt-check"] --> DC["docs-check"] --> T["test (Debug)"] --> TR["test-release (ReleaseSafe)"] --> B["build"]
    end

    subgraph EXT["just ci-extended (scripts/gate.py, macOS only)"]
        direction TB
        X0["sh -n on .githooks/pre-*<br/>bash -n on scripts/*.sh"] --> X1["just ci"]
        X1 --> X2["test ReleaseFast"]
        X2 --> X3["python tooling tests"]
        X3 --> X4["zig build docs"]
        X4 --> X5["zig build examples-check"]
        X5 --> X6["scripts/compatibility.py"]
        X6 --> X7["bench smoke: 20 normal 1"]
        X7 --> X8["scripts/demo-smoke.py"]
    end

    subgraph FULL["just ci-full"]
        EXT2["ci-extended"] --> CS["canary-strict"]
    end

    CI -. "included in" .-> EXT
    EXT -. "included in" .-> FULL
```

`gate.py` runs each command under a process-group supervisor with a
per-command deadline (`LOCAL_GATE_TIMEOUT_SECONDS`, default 300, allowed
range 1 to 3600).

| Check | Purpose |
|---|---|
| `fmt-check` | `zig fmt --check` over `build.zig`, `src`, `examples`, `tests`, `bench`, `scripts`. |
| `docs-check` | `scripts/docs-check.sh`. The README `## Layout` table must list exactly the `.zig` files under `src/`, `examples/` and `tests/`, and every README `zig` block that calls `Client.open` must compile against `src/agent.zig`. |
| `canary` / `canary-strict` | Checks the installed CLI version against `min_cli_version`, its advertised flags and permission modes, and parser-only probes for each flag `buildArgv` emits. No model request. The strict form fails if the CLI is missing or a probe is inconclusive. |
| `compatibility` | Runs the public client against a hand-written synthetic protocol fixture. Not a recorded CLI transcript. |
| `tooling-test` | Offline tests for the Python delivery scripts. |
| `runtime-validate PATH` | Fresh Debug, ReleaseSafe and ReleaseFast runs of each test root, 100 stress repetitions per race group, generated fuzzing, and source fingerprints written to a new ignored directory. |
| `compatibility-live PATH` | Opt-in live CLI matrix (needs `--allow-model-use`): seven scenarios covering MCP, permissions, interrupt, rejection and resume. At most eight clients, USD 0.05 per-client budget thresholds, 60 s per scenario, sanitized evidence. Never part of a gate. |

## Git hooks

```mermaid
sequenceDiagram
    participant Dev
    participant Git
    participant PC as .githooks/pre-commit
    participant PP as .githooks/pre-push
    participant WT as temporary worktree

    Dev->>Git: just hooks-install (core.hooksPath = .githooks)
    Dev->>Git: git commit
    Git->>PC: run
    PC->>PC: just fmt-check, just docs-check (working tree)
    PC-->>Git: pass or block
    Dev->>Git: git push
    Git->>PP: run with pushed refs
    loop each distinct pushed tip (deletes skipped)
        PP->>WT: detached worktree at tip
        WT->>WT: just ci (that tip's justfile)
        WT-->>PP: pass or fail
        PP->>WT: remove worktree
    end
    PP-->>Git: pass or block
```

Both hooks can be skipped with `--no-verify`, and nothing enforces them on
the remote. They catch mistakes; they are not a control against a hostile
committer. Intermediate commits in a pushed range are not tested.

## Benchmark

`bench/next_bench.zig` feeds a synthetic transcript through a real pipe and
times `Client.next()` (default) or `nextView()` (fourth argument `view`). Each
repetition prints one JSONL record with an explicit `event_mode`:

| Workload | Shape |
|---|---|
| `normal` | Ordinary text deltas. |
| `escaped` | Deltas with heavy JSON escaping. |
| `large` | 8 KiB deltas. |
| `control` | One dispatched MCP tool call per delta. |
| `recovery` | One 2 MiB event, then normal deltas, to check buffer release. |
| `all` | Each of the above. |

Each record includes `zig_version`, optimize mode, target, throughput,
p50/p95/p99/max latency, allocations and bytes per event, and peak, retained
and after-close SDK memory. Use at least five ReleaseFast runs. A repeatable
regression above 10% in median throughput or allocated bytes per event is
worth investigating. `scripts/bench_compare.py` runs seeded, balanced
before/after pairs with build and source fingerprints.
It validates the requested read mode against every sample. Use `--event-mode`
for both executables, or explicit `--before-event-mode` and `--after-event-mode`
overrides to compare the owned and borrowed APIs deliberately.

## Release pipeline

```mermaid
flowchart TD
    A(["just release VERSION"]) --> B{"clean tree?"}
    B -- no --> R[["REFUSED"]]
    B -- yes --> C{"VERSION equals build.zig.zon .version?"}
    C -- no --> R
    C -- yes --> D{"CHANGELOG has a heading for VERSION?"}
    D -- no --> R
    D -- yes --> E{"tag vVERSION absent or at HEAD?"}
    E -- no --> R
    E -- yes --> F["just ci-full"]
    F -- fail --> R
    F -- pass --> G["release_artifacts.py create"]
    G --> H["dist/: git archive tarball,<br/>CycloneDX 1.5 SBOM,<br/>SHA256SUMS"]
    H --> I{"RELEASE_SIGNING_KEY set?"}
    I -- yes --> J["ssh-keygen -Y sign SHA256SUMS"]
    I -- no --> K
    J --> K["release_artifacts.py verify"]
    K --> L(["print git tag -a command and stop"])

    L -. "owner decides" .-> M["tag and push"]

    V(["just release-verify VERSION"]) --> V1["check every archive entry and exact source membership"]
    V1 --> V2["check SHA256SUMS and SBOM metadata"]
    V2 --> V3{"RELEASE_ALLOWED_SIGNERS set?"}
    V3 -- yes --> V4["verify signature"]
    V3 -- no --> V5["integrity only: provenance not authenticated"]
    V4 --> V6["build an extracted package consumer"]
    V5 --> V6
```

The release scripts never commit, tag or push.

## Consuming the package

Once a tag exists:

```
zig fetch --save git+https://github.com/cipher-rc5/claude_agent_zig#v0.1.0
```

```zig
const agent = b.dependency("claude_agent", .{ .target = target, .optimize = optimize }).module("agent");
exe.root_module.addImport("agent", agent);
```

The package ships what `build.zig.zon` `.paths` lists: `build.zig`,
`build.zig.zon`, `src`, `examples`, `tests` and the top-level documents.
`bench/`, `scripts/`, `.githooks/`, the `justfile` and `docs/` are tracked in
git but are not part of the package.

## Environment variables

| Variable | Read by | Meaning |
|---|---|---|
| `CLAUDE_BIN` | demo, examples, `justfile`, canary | CLI binary. Default `claude`. |
| `AGENT_SKILLS` | demo | Comma-separated skill allowlist. Unset allows all, empty allows none. |
| `AGENT_PERMISSIONS` | demo | `host` installs the demo's log-and-allow permission handler. |
| `AGENT_OUTPUT` | demo | `auto` flushes terminal deltas and buffers redirected output; `stream` flushes every delta; `buffered` flushes at results/EOF; `final` also disables partial messages. |
| `LOCAL_GATE_TIMEOUT_SECONDS` | `scripts/gate.py` | Per-command deadline in seconds. |
| `RELEASE_SIGNING_KEY` | `release.sh` | SSH private key used to sign `SHA256SUMS`. |
| `RELEASE_ALLOWED_SIGNERS` | `release-verify.sh` | `allowed_signers` file; enables signature checking. |
| `RELEASE_SIGNER_IDENTITY` | `release-verify.sh` | Optional principal override. |
