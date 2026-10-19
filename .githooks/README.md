# .githooks

Version-controlled git hooks for this repo. CI here is strictly local — there
is no GitHub Actions workflow and no cloud runner, by decision. Two hooks make
up the gate: `pre-commit` for the fast checks, `pre-push` for the full ones.

## Install

    just hooks-install

That runs `git config core.hooksPath .githooks`. Using `core.hooksPath` rather
than copying files into `.git/hooks` keeps the hooks under version control, so
a fix to the gate reaches everyone on the next pull.

Remove it with:

    just hooks-uninstall

## pre-commit

Runs the two checks that are fast enough to sit in front of every commit:

- `zig fmt --check build.zig src examples tests bench scripts`
- `bash scripts/docs-check.sh` — the README Layout table against the real
  tree, and the README usage example recompiled against the current API.

It checks the working tree, not the index. That is deliberate for a fast
gate: what `zig fmt` and the docs check see on disk is what was just saved,
and the verdict that matters — on the commit itself — comes at push time.
Needs `zig` on PATH and fails closed without it.

Bypass a single commit with `git commit --no-verify`. The pre-push gate still
runs on that commit.

## pre-push

Gates each distinct **pushed ref tip**, using the committed tree. It does not
validate intermediate commits in a newly pushed range. Git hands the hook
each ref on stdin as `<local-ref> <local-sha> <remote-ref> <remote-sha>`; for
every distinct non-zero local SHA the hook:

1. checks that commit out detached into a temporary worktree
   (`git worktree add --detach`, under `$TMPDIR`);
2. runs `just ci` there — `fmt-check`, `docs-check`, `test`, `test-release`,
   `build` — using that commit's own `justfile`;
3. removes the worktree (`git worktree remove --force`, then `prune`) on
   every exit path, including a failure or an interrupt.

A dirty working tree, or pushing a branch other than the one checked out,
therefore cannot make a green result mean anything other than "this commit
passes". Two refs at the same commit are gated once. A ref delete
(`git push origin :branch`) has no tree and is skipped with a note. A sha
that cannot be checked out blocks the push rather than passing.

The worktree shares the main tree's `.zig-cache` (`ZIG_LOCAL_CACHE_DIR`), so
the gate is incremental rather than a cold rebuild in two optimize modes.

If `just` is not installed the hook runs the same steps directly with `zig`
and `bash scripts/docs-check.sh`, rather than passing silently. If neither
`just` nor `zig` is on PATH the push is blocked.

Bypass a single push with `git push --no-verify`. Doing so skips the only CI
this repository has.

## Related recipes

- `just ci` — the gate the pre-push hook runs per distinct ref tip.
- `just docs-check` — the README drift check. Part of `ci` and `pre-commit`.
- `just test-release` — the suite under ReleaseSafe. Part of `ci`.
- `just canary` — checks that the installed Claude Code CLI meets the version
  floor in `src/options.zig` and still accepts every flag and permission-mode
  value the client emits. Not in `ci` because it needs the `claude` binary;
  skips cleanly when absent.
- `just canary-schedule-install` — runs `canary` weekly via launchd on macOS
  (prints a crontab line elsewhere). `just canary-schedule-uninstall` removes
  it.
- `just tooling-test` — disposable canary, signature, artifact, process cleanup,
  and pushed-tip hook tests. Requires Python 3.12+ and OpenSSH; no model calls.
- `just compatibility` — synthetic offline initialization, MCP list/call,
  permission allow/deny, interrupt, and resume fixtures through the public client.
  Fixtures check implementation behavior; they are not current CLI recordings.
- `just compatibility-live PATH` — explicitly opts into seven real CLI semantic
  scenarios with harmless SDK tools in temporary workspaces. Eight CLI clients
  have USD 0.05 per-client budget thresholds and 60-second scenario deadlines.
  Thresholds are not billing guarantees. Sanitized evidence includes the explicit
  invalid-subtype rejection fault and cleanup of owned session artifacts.
  The underlying script requires `--allow-model-use`. Never run by another gate.
- `just ci-extended` — bounded `ci`, ReleaseFast tests, tooling tests, API docs,
  compiled examples, offline fixtures, and benchmark/demo smoke on macOS.
  It does not use a model. Each command has a 300-second
  process-group deadline (`LOCAL_GATE_TIMEOUT_SECONDS`, range 1–3600).
- `just canary-strict` — parser checks that fail if the CLI is missing, times out,
  or fails for an unrelated reason. It does not validate live model behavior.
- `just ci-full` — `ci-extended` plus `canary-strict`; required by `just release`.
- `just release-verify VERSION` — verify all entries against the trusted local
  HEAD, exact checksums, structured SBOM metadata, and a separate extracted Zig
  dependency consumer. Pass `--commit FULL_SHA` to the script when verifying an
  older release. Python 3.12+ is developer tooling, not a package dependency.
  Set `RELEASE_ALLOWED_SIGNERS` to authenticate the checksum manifest; add
  `--require-signature` to the script to fail without configured trust. Integrity
  checks alone do not establish signer provenance.
