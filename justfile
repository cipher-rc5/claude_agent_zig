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
    zig fmt build.zig src

# Fail if any Zig source is unformatted; use in CI.
fmt-check:
    zig fmt --check build.zig src

# fmt-check, test, then build — the pre-commit gate.
ci: fmt-check test build

# Remove build outputs and the local Zig cache.
clean:
    rm -rf zig-out .zig-cache

# Print the toolchain versions this repo is being built with.
versions:
    @zig version
    @{{CLAUDE_BIN}} --version 2>/dev/null || echo "claude: not found on PATH"
