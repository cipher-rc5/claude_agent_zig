# justfile — task runner for claude_agent_zig
# Run `just` with no arguments to list every recipe.

# Path to the Claude Code CLI the agent spawns.
export CLAUDE_BIN := env_var_or_default("CLAUDE_BIN", "claude")
# Comma list restricting which skills the agent may invoke. Unset means all.
export AGENT_SKILLS := env_var_or_default("AGENT_SKILLS", "")

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

# fmt-check, test, then build — the pre-commit gate.
ci: fmt-check test build

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
        if printf '%s' "$help" | grep -q -- "$flag"; then
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

    # Permission-mode values emitted by src/options.zig cliName().
    choices="$(printf '%s' "$help" | grep -A6 -- '--permission-mode')"
    for mode in manual auto dontAsk acceptEdits plan; do
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
