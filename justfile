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

# The client reasons about release modes explicitly (asserts that vanish under
# ReleaseFast, safety checks that stay under ReleaseSafe), so the gate runs the
# suite under one of them too, not only Debug.
# Run the unit tests under ReleaseSafe.
test-release:
    zig build test -Doptimize=ReleaseSafe

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
    zig fmt build.zig src examples tests bench

# Fail if any Zig source is unformatted; use in CI.
fmt-check:
    zig fmt --check build.zig src examples tests bench

# Doc-vs-code drift is this repo's dominant defect class, and fmt/test/build
# are all blind to it. Checks the README Layout table against the real tree and
# recompiles the README's usage example against the current API.
# Fail if README.md has drifted from the code.
docs-check:
    @bash scripts/docs-check.sh

# fmt-check, docs-check, test, test-release, then build — the pre-push gate.
ci: fmt-check docs-check test test-release build

# Numbers only mean something under a release mode; Debug measures the
# allocator's bookkeeping more than the parser. Pass a line count to change
# the transcript size.
# Measure Client.next() over a synthetic stream_event transcript.
bench lines="20000":
    zig build bench -Doptimize=ReleaseFast -- {{lines}}

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

# Hooks live in the repo, not in .git/hooks, so they stay version-controlled.
# Enable the pre-commit and pre-push local CI gates by pointing git at .githooks/.
hooks-install:
    git config core.hooksPath .githooks
    @echo "hooks installed: core.hooksPath = .githooks"
    @echo "  pre-commit runs fmt-check + docs-check on the tree"
    @echo "  pre-push   runs 'just ci' on each commit being pushed, in a temporary worktree"

# Stop git from using .githooks/; commits and pushes will no longer run the local gates.
hooks-uninstall:
    git config --unset core.hooksPath
    @echo "hooks uninstalled: core.hooksPath cleared"

# The Claude Code CLI is externally versioned, so an upgrade can silently
# break this client. Skips cleanly (exit 0) when the CLI is not installed.
# Check the CLI meets the version floor and still accepts every flag and permission mode we emit.
canary:
    #!/usr/bin/env bash
    set -uo pipefail
    bin="${CLAUDE_BIN:-claude}"
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "canary: SKIP — '$bin' not on PATH; cannot check the CLI wire protocol."
        exit 0
    fi
    version_line="$("$bin" --version 2>/dev/null || echo unknown)"
    echo "canary: checking $version_line"
    help="$("$bin" --help 2>&1)"
    fail=0

    # Version floor, declared once in src/options.zig as
    # `pub const min_cli_version = "X.Y.Z";` and parsed out of the source
    # rather than repeated here. An empty parse is a failure, not a pass: a
    # renamed or reformatted declaration must not silently lift the floor.
    floor="$(sed -n 's/^pub const min_cli_version = "\([^"]*\)";.*/\1/p' src/options.zig | head -n 1)"
    installed="${version_line%% *}"
    if [ -z "$floor" ]; then
        echo "  MISSING min_cli_version — could not parse 'pub const min_cli_version = \"X.Y.Z\";' out of src/options.zig."
        echo "          The canary refuses to pass without a version floor."
        fail=1
    elif ! printf '%s' "$installed" | grep -qE '^[0-9]+(\.[0-9]+)+$'; then
        echo "  MISSING CLI version — '$bin --version' gave '$version_line', which is not a version."
        fail=1
    elif [ "$(printf '%s\n%s\n' "$floor" "$installed" | sort -V | head -n 1)" != "$floor" ]; then
        echo "  TOO OLD installed CLI $installed is below the floor $floor declared in src/options.zig"
        fail=1
    else
        echo "  ok      CLI $installed >= floor $floor (src/options.zig min_cli_version)"
    fi

    # Flags discoverable in --help. NOTE: --max-turns is deliberately NOT in
    # this list. It is accepted by the CLI but undocumented in --help, so a
    # help-grep would report a false positive. It is probed directly below.
    for flag in --print --input-format --output-format --verbose --bare \
                --include-partial-messages --model --allowedTools \
                --permission-mode --permission-prompts --append-system-prompt \
                --tools --setting-sources --add-dir --plugin-dir --agents \
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

    # --permission-prompt-tool is what makes the CLI emit can_use_tool control
    # requests (measured: --permission-prompts host alone emits none). It is
    # also absent from --help, so it is probed by rejection the same way.
    probe="$("$bin" --print --permission-prompt-tool stdio --definitely-not-a-real-flag-xyz 2>&1 || true)"
    if printf '%s' "$probe" | grep -qi -- "--permission-prompt-tool"; then
        echo "  MISSING --permission-prompt-tool (CLI rejected it as an unknown option)"
        fail=1
    else
        echo "  ok      --permission-prompt-tool (undocumented in --help; accepted by the parser)"
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
        echo "canary: FAIL — the CLI no longer matches what this client expects."
        echo "        Reconcile src/options.zig with the installed CLI before shipping."
        exit 1
    fi
    echo "canary: PASS — the CLI meets the version floor and accepts every flag and permission mode this client emits."

# Needs the claude binary and is slower than ci; run before cutting a
# release or after a CLI upgrade.
# ci plus the CLI wire-protocol canary.
ci-full: ci canary

# The canary only catches drift if something runs it, and nobody remembers
# `just ci-full` the week after a CLI upgrade. On macOS this installs a launchd
# agent that runs it every Monday at 09:00 and appends to
# ~/Library/Logs/claude_agent_zig-canary.log. Elsewhere it prints the crontab
# line to add by hand. PATH is captured now, because launchd starts agents
# with almost none and `just`, `zig` and `claude` all live outside it.
# Schedule `just canary` weekly (launchd on macOS; prints a crontab line elsewhere).
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
    # Reload if a previous install is still registered, so an edit takes.
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

# Cuts release artefacts into dist/ and prints the tag command. It never
# tags, commits or pushes: those stay the owner's call. See scripts/release.sh.
# Build dist/ for <version>: tarball, SHA256SUMS, CycloneDX SBOM, optional signature.
release version:
    @bash scripts/release.sh {{version}}

# Check dist/ for <version>: sums, and the signature when RELEASE_ALLOWED_SIGNERS is set.
release-verify version:
    @bash scripts/release-verify.sh {{version}}
