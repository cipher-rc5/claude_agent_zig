# .githooks

Version-controlled git hooks for this repo. CI here is strictly local — there
is no GitHub Actions workflow and no cloud runner. The gate is a `pre-push`
hook.

## Install

    just hooks-install

That runs `git config core.hooksPath .githooks`. Using `core.hooksPath` rather
than copying files into `.git/hooks` keeps the hooks under version control, so
a fix to the gate reaches everyone on the next pull.

Remove it with:

    just hooks-uninstall

## pre-push

Runs `just ci` (`fmt-check`, `docs-check`, `test`, `build`) and exits non-zero
on failure, so the push is actually blocked. If `just` is not installed it falls
back to the equivalent raw `zig` commands rather than passing silently.

It also reads the refs git passes on stdin and warns — without blocking — when
the commit being pushed is not `HEAD`, or when the working tree is dirty. In
either case the gate is testing something other than what is being pushed, and
the warning says so.

Bypass a single push with `git push --no-verify`.

## Related recipes

- `just ci` — the fast gate the hook runs.
- `just docs-check` — README Layout table vs the real tree, and the README
  usage example recompiled against the current API. Part of `ci`.
- `just canary` — checks that every CLI flag and permission-mode value the
  client emits is still accepted by the installed Claude Code CLI. Not in `ci`
  because it needs the `claude` binary; skips cleanly when absent.
- `just ci-full` — `ci` plus `canary`.
