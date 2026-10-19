# justfile — task runner for claude_agent_zig
# Run `just` with no arguments to list every recipe.

# Path to the Claude Code CLI the agent spawns.
export CLAUDE_BIN := env_var_or_default("CLAUDE_BIN", "claude")
# Inherit AGENT_SKILLS unchanged: unset allows all skills, empty allows none.
# Exporting an empty default here would disable skills for every demo run.

default:
    @just --list

# Build the executable into zig-out/bin/.
build:
    zig build

# Run the unit tests across all modules.
test:
    zig build test --test-timeout 10s

# Run the unit tests under ReleaseSafe to check release-mode behavior.
test-release:
    zig build test -Doptimize=ReleaseSafe --test-timeout 10s

# Example: just dev "explain this repo"
# Build and run one agent turn with an optional prompt.
dev prompt="What is 17 plus 25? Use the add tool.":
    zig build run -- {{quote(prompt)}}

# Run one agent turn with a release build.
dev-release prompt="What is 17 plus 25? Use the add tool.":
    zig build run -Doptimize=ReleaseFast -- {{quote(prompt)}}

# Compile and test with a full step summary.
check:
    zig build --summary all
    zig build test --summary all

# Format all Zig sources in place.
fmt:
    zig fmt build.zig src examples tests bench scripts

# Fail if any Zig source is unformatted; use in CI.
fmt-check:
    zig fmt --check build.zig src examples tests bench scripts

# Check the README Layout table and compile its usage examples.
docs-check:
    @bash scripts/docs-check.sh

# Run formatting, documentation, Debug/ReleaseSafe tests, and build checks.
ci: fmt-check docs-check test test-release build

# Measure Client.next() throughput, latency, and allocations.
bench lines="20000" workload="normal" runs="1":
    zig build bench -Doptimize=ReleaseFast -- {{quote(lines)}} {{quote(workload)}} {{quote(runs)}}

# Emit the agent module's autodocs into zig-out/docs/.
docs:
    zig build docs
    @echo "docs: zig-out/docs/index.html"

# Remove build outputs and the local Zig cache.
clean:
    rm -rf zig-out .zig-cache

# Print the toolchain versions this repo is being built with.
versions:
    @zig version
    @{{CLAUDE_BIN}} --version 2>/dev/null || echo "claude: not found on PATH"

# Enable the version-controlled pre-commit and pre-push hooks in .githooks/.
hooks-install:
    git config core.hooksPath .githooks
    @echo "hooks installed: core.hooksPath = .githooks"
    @echo "  pre-commit runs fmt-check + docs-check on the tree"
    @echo "  pre-push   runs 'just ci' on each distinct pushed ref tip, in a temporary worktree"

# Disable the local pre-commit and pre-push gates.
hooks-uninstall:
    git config --unset core.hooksPath
    @echo "hooks uninstalled: core.hooksPath cleared"

# Probe CLI parser compatibility without model requests; skip a missing CLI.
canary:
    @python3 scripts/canary.py

# Fail if the CLI is missing, incompatible, or its parser probes are inconclusive.
canary-strict:
    @python3 scripts/canary.py --strict

# Run disposable canary, artifact, signature, supervisor, and hook tests offline.
tooling-test:
    @python3 -B -m unittest discover -s scripts -p '*_test.py' -v

# Record fresh native tests, stress, and fuzz evidence in a new directory.
runtime-validate output:
    @python3 -B scripts/runtime_validation.py --output {{quote(output)}} --strict-canary

# Compile and exercise offline protocol fixtures through the public client.
compatibility:
    @python3 scripts/compatibility.py

# Opt into the bounded live CLI matrix and save evidence in a new directory.
compatibility-live output:
    @python3 -B scripts/live-compatibility.py --allow-model-use --evidence-dir {{quote(output)}}

# Bound every command in the native macOS gate.
ci-extended:
    @python3 scripts/gate.py

# Release validation requires completed local checks and CLI parser probes.
ci-full: ci-extended canary-strict

# Schedule Monday 09:00 canary checks via launchd; print a cron entry elsewhere.
# Capture PATH at installation so launchd can find just, zig, and claude.
# Schedule weekly CLI compatibility checks.
canary-schedule-install:
    #!/usr/bin/env bash
    set -euo pipefail
    label="com.cipher-rc5.claude-agent-zig.canary"
    justfile="{{justfile()}}"
    just_bin="{{just_executable()}}"
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "canary-schedule: not macOS; add this line with 'crontab -e' instead:"
        echo "  0 9 * * 1 cd '{{justfile_directory()}}' && '$just_bin' --justfile '$justfile' canary >> \"\$HOME/claude_agent_zig-canary.log\" 2>&1"
        exit 0
    fi
    plist="$HOME/Library/LaunchAgents/$label.plist"
    log="$HOME/Library/Logs/claude_agent_zig-canary.log"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>$label</string>
        <key>ProgramArguments</key>
        <array>
            <string>$just_bin</string>
            <string>--justfile</string>
            <string>$justfile</string>
            <string>canary</string>
        </array>
        <key>WorkingDirectory</key><string>{{justfile_directory()}}</string>
        <key>EnvironmentVariables</key>
        <dict>
            <key>PATH</key><string>$PATH</string>
            <key>CLAUDE_BIN</key><string>${CLAUDE_BIN:-claude}</string>
        </dict>
        <key>StartCalendarInterval</key>
        <dict>
            <key>Weekday</key><integer>1</integer>
            <key>Hour</key><integer>9</integer>
            <key>Minute</key><integer>0</integer>
        </dict>
        <key>StandardOutPath</key><string>$log</string>
        <key>StandardErrorPath</key><string>$log</string>
    </dict>
    </plist>
    PLIST
    # Reload an existing registration to apply changes.
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    echo "canary-schedule: installed $plist"
    echo "  runs '$just_bin --justfile $justfile canary' every Monday 09:00"
    echo "  log: $log"
    echo "  remove with: just canary-schedule-uninstall"

# Remove the weekly canary schedule installed by canary-schedule-install.
canary-schedule-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    label="com.cipher-rc5.claude-agent-zig.canary"
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "canary-schedule: not macOS; remove the '$label' line with 'crontab -e'."
        exit 0
    fi
    plist="$HOME/Library/LaunchAgents/$label.plist"
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    if [ -f "$plist" ]; then
        rm -f "$plist"
        echo "canary-schedule: removed $plist"
    else
        echo "canary-schedule: nothing installed at $plist"
    fi

# Prints the tag command; tagging, committing, and pushing remain manual.
# Build a tarball, SBOM, checksums, and optional signature in dist/.
release version:
    @bash scripts/release.sh {{version}}

# Verify all entries, SBOM, checksums, optional trust, and an extracted consumer.
release-verify version:
    @bash scripts/release-verify.sh {{version}}
