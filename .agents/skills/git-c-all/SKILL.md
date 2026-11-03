---
name: git-c-all
description: Stage, commit, and push all intended claude_agent_zig changes when asked to commit everything, commit and push all, or push all changes. Use local Zig gates and an explicit current-branch refspec. Editing this skill does not authorize committing or pushing.
---

# Commit and push SDK changes

Run mutation steps only when requested. A commit-only request authorizes no push. Follow `CONTRIBUTING.md` and keep private `_dev/` evidence out of Git.

## Inspect and validate

1. Inspect `git status --short`, `git diff HEAD`, `git diff --cached`, recent commit subjects, current branch, remotes, and upstream. Read relevant untracked files separately; they are absent from `git diff HEAD`. Never print credential-bearing remote URLs.
2. Preserve user changes and inventory all intended files before `git add -A`. Never force-add `_dev/`, `.zig-cache/`, `zig-out/`, `dist/`, credentials, or generated evidence. Check suspicious paths with `git check-ignore -v`.
3. Inspect `justfile` and both `.githooks/pre-*` hooks. This SDK uses the exact manifest Zig pin, `zig fmt`, and Python/shell tooling. There is no TypeScript application manifest; do not invent frontend/typecheck commands. If new packages exist, inspect their actual manifests and applicable rules.
4. Before committing run `just fmt-check` and `just docs-check` unless already passed on the same snapshot. For Zig behavior run relevant tests; use `just ci` for the full SDK gate. Use `just tooling-test` for delivery-tool behavior and `just compatibility` for protocol fixtures as appropriate. Skill-only Markdown changes need skill validation/reference checks rather than unrelated runtime tests.
5. Consumer-visible API changes need consistent `src/agent.zig` exports, README Layout/Usage, reachable tests, and `[Unreleased]` notes. Public tests import `agent`; do not widen private API to move tests.

Pre-commit checks the working tree. Pre-push runs each distinct pushed ref tip's `just ci` in a temporary worktree, not every intermediate commit. Hooks are opt-in; inspect `core.hooksPath`, but do not configure/install them implicitly. If the push gate is absent, run `just ci` on the exact commit before pushing. Avoid redundant successful checks; do not bypass failed hooks without explicit instruction. Report missing tools and failures.

## Commit

- Inspect staged paths, `git diff --cached --stat`, and `git diff --cached`. Do not create an empty commit. With nothing staged, still check existing unpushed commits if pushing was explicitly requested.
- Read the canonical [Conventional Commits specification](https://www.conventionalcommits.org/en/v1.0.0/#specification) before composing a message when applicable rules require it. Use `<type>[optional scope]: <imperative summary>`, at most 72 subject characters, matching actual scope/history. Useful scopes include `client`, `protocol`, `transport`, `options`, `tools`, `tests`, `docs`, and `release`.
- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. Mark breaking public API changes. Explain non-obvious reasons in a short body.
- No AI-author credits, generated-by claims, or co-author trailers. Product names such as Claude Code are valid descriptions of changed software.
- Put exact multiline message text in a temporary file and run `git commit -F <message-file>`; keep content out of shell interpolation. Do not amend published commits or rewrite history unless requested.

## Push and report

- Re-read the branch before pushing. For detached HEAD do not guess a destination. Resolve conflicting destination information before mutation; explicit user instructions take precedence.
- Normally use `git push origin HEAD:refs/heads/<branch>` with the observed branch shell-quoted; add `-u` without an upstream. If the configured upstream differs, honor its remote/branch with both refspec ends explicit. Never use bare `git push` or push tags incidentally.
- Do not force-push. On rejection preserve the commit and report the cause; do not reset/rebase automatically. A push request does not authorize release creation, publishing private findings, or hook/schedule changes.
- Confirm hash/subject, destination, push result, and validation. Disclose files changed by hooks/concurrent work instead of silently making another commit.
