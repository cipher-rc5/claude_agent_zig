# justfile — task runner for claude_agent_zig
# Run `just` with no arguments to list every recipe.

# Path to the Claude Code CLI the agent spawns.
export CLAUDE_BIN := env_var_or_default("CLAUDE_BIN", "claude")
# AGENT_SKILLS is deliberately NOT exported here. The demo distinguishes unset
# (every discovered skill may be invoked) from empty (none may be), and `just`
# cannot export a variable only when it already exists — an
# `env_var_or_default(..., "")` export sets it to empty on every run, which
# turned the documented default into its exact opposite: `just dev` could invoke
# no skills at all. Left alone, the caller's environment passes straight
# through, so `AGENT_SKILLS=a,b just dev` still scopes a run and a bare
# `just dev` still gets the documented default.

default:
    @just --list

# Build the executable into zig-out/bin/.
build:
    zig build

# Run the unit tests across all modules.
test:
    zig build test

# Build and run one turn against the agent. Pass a prompt, or take the default.
# Example: just dev "explain this repo"
dev prompt="What is 17 plus 25? Use the add tool.":
    zig build run -- {{quote(prompt)}}

# Same as dev, but with a release build.
dev-release prompt="What is 17 plus 25? Use the add tool.":
    zig build run -Doptimize=ReleaseFast -- {{quote(prompt)}}

# Compile and test with a full step summary.
check:
    zig build --summary all
    zig build test --summary all

# Format all Zig sources in place.
fmt:
    zig fmt build.zig src examples tests

# Fail if any Zig source is unformatted; use in CI.
fmt-check:
    zig fmt --check build.zig src examples tests

# Doc-vs-code drift is this repo's dominant defect class, and fmt/test/build
# are all blind to it. Checks the README Layout table against the real tree and
# recompiles the README's usage example against the current API.
# Fail if README.md has drifted from the code.
docs-check:
    @bash scripts/docs-check.sh

# fmt-check, docs-check, test, then build — the pre-commit gate.
ci: fmt-check docs-check test build

# Remove build outputs and the local Zig cache.
clean:
    rm -rf zig-out .zig-cache

# Print the toolchain versions this repo is being built with.
versions:
    @zig version
    @{{CLAUDE_BIN}} --version 2>/dev/null || echo "claude: not found on PATH"

# Hooks live in the repo, not in .git/hooks, so they stay version-controlled.
# Enable the pre-push local CI gate by pointing git at .githooks/.
hooks-install:
    git config core.hooksPath .githooks
    @echo "hooks installed: core.hooksPath = .githooks (pre-push runs 'just ci')"

# Stop git from using .githooks/; pushes will no longer run the local gate.
hooks-uninstall:
    git config --unset core.hooksPath
    @echo "hooks uninstalled: core.hooksPath cleared"

# The Claude Code CLI is externally versioned, so an upgrade can silently
# break this client. Skips cleanly (exit 0) when the CLI is not installed.
# Check the CLI still accepts every flag and permission mode we emit.
canary:
    #!/usr/bin/env bash
    set -uo pipefail
    bin="${CLAUDE_BIN:-claude}"
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "canary: SKIP — '$bin' not on PATH; cannot check the CLI wire protocol."
        exit 0
    fi
    echo "canary: checking $("$bin" --version 2>/dev/null || echo unknown)"
    help="$("$bin" --help 2>&1)"
    fail=0

    # Flags discoverable in --help. NOTE: --max-turns is deliberately NOT in
    # this list. It is accepted by the CLI but undocumented in --help, so a
    # help-grep would report a false positive. It is probed directly below.
    for flag in --print --input-format --output-format --verbose --bare \
                --include-partial-messages --model --allowedTools \
                --permission-mode --append-system-prompt --tools \
                --setting-sources --add-dir --plugin-dir --agents \
                --disable-slash-commands --strict-mcp-config --mcp-config \
                --resume; do
        # Anchored on both sides. An unanchored substring match reports
        # `ok --add-dir` when the CLI has actually renamed the flag to
        # --add-dirs, which is exactly the drift this canary exists to catch.
        # A real occurrence is preceded by start-of-line or whitespace and
        # followed by whitespace, a comma, '<', '=', or end-of-line.
        if printf '%s' "$help" | grep -qE -- "(^|[[:space:]])${flag}([[:space:],<=]|$)"; then
            echo "  ok      $flag"
        else
            echo "  MISSING $flag"
            fail=1
        fi
    done

    # Undocumented but accepted: probe by rejection. An unknown flag makes the
    # CLI print "unknown option"; a known one does not. No API call is made
    # because argument parsing fails (or succeeds) before the request.
    probe="$("$bin" --print --max-turns 3 --definitely-not-a-real-flag-xyz 2>&1 || true)"
    if printf '%s' "$probe" | grep -qi -- "--max-turns"; then
        echo "  MISSING --max-turns (CLI rejected it as an unknown option)"
        fail=1
    else
        echo "  ok      --max-turns (undocumented in --help; accepted by the parser)"
    fi

    # Permission-mode values emitted by src/options.zig cliName(). Derived from
    # the source rather than hardcoded here: a hardcoded list silently drifts
    # when a mode is added, and the mode that went missing last time was
    # bypassPermissions — the one that disables every permission check.
    # cliName() is a flat `.tag => "wireName",` switch, so the wire names are
    # exactly the quoted strings on its `=>` arms.
    modes="$(awk '
        /pub fn cliName/ { in_fn = 1; next }
        in_fn && /^[[:space:]]*}[[:space:]]*$/ { in_fn = 0 }
        in_fn && /=>/ { if (match($0, /"[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2) }
    ' src/options.zig)"
    if [ -z "$modes" ]; then
        echo "  MISSING permission modes — could not parse cliName() out of src/options.zig."
        echo "          The canary refuses to pass on an empty mode list."
        fail=1
    fi
    echo "  modes emitted by src/options.zig cliName(): $(printf '%s' "$modes" | tr '\n' ' ')"

    choices="$(printf '%s' "$help" | grep -A6 -- '--permission-mode')"
    for mode in $modes; do
        if printf '%s' "$choices" | grep -q -- "\"$mode\""; then
            echo "  ok      --permission-mode $mode"
        else
            echo "  MISSING --permission-mode $mode"
            fail=1
        fi
    done

    if [ "$fail" -ne 0 ]; then
        echo "canary: FAIL — the CLI no longer accepts something this client emits."
        echo "        Reconcile src/options.zig with the installed CLI before shipping."
        exit 1
    fi
    echo "canary: PASS — every flag and permission mode this client emits is still accepted."

# Needs the claude binary and is slower than ci; run before cutting a
# release or after a CLI upgrade.
# ci plus the CLI wire-protocol canary.
ci-full: ci canary
