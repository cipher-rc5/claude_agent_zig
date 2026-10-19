#!/usr/bin/env bash
# scripts/docs-check.sh
# Checks the README Layout table and compiles complete Zig usage examples. Runs
# offline without the CLI or executing compiled examples.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

readme="README.md"
fail=0

if [ ! -f "$readme" ]; then
    echo "docs-check: FAIL — $readme not found."
    exit 1
fi

# Layout table
echo "docs-check: [layout] README '## Layout' table vs the real tree"

actual="$(find src examples tests -name '*.zig' -type f 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort)"

# Read backticked .zig paths from the Layout section until the next heading.
documented="$(awk '
    /^## Layout[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^\|/ { print }
' "$readme" | grep -o '`[^`]*\.zig`' | tr -d '`' | LC_ALL=C sort -u)"

if [ -z "$documented" ]; then
    echo "  FAIL: no .zig entries found in the '## Layout' table."
    echo "        Either the section is missing/renamed, or the table is mid-edit."
    fail=1
else
    missing="$(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$documented"))"
    extra="$(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$documented"))"
    if [ -n "$missing" ]; then
        echo "  FAIL: on disk but absent from the Layout table:"
        printf '          %s\n' $missing
        fail=1
    fi
    if [ -n "$extra" ]; then
        echo "  FAIL: in the Layout table but not on disk:"
        printf '          %s\n' $extra
        fail=1
    fi
    if [ -z "$missing" ] && [ -z "$extra" ]; then
        echo "  ok: $(printf '%s\n' "$actual" | wc -l | tr -d ' ') .zig files, table matches the tree exactly."
    fi
fi

# Usage examples
echo "docs-check: [usage] README \`\`\`zig blocks compile against src/agent.zig"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Extract Zig blocks, numbered by their opening line for diagnostics.
awk -v dir="$work" '
    /^```zig[[:space:]]*$/ { inblk = 1; start = NR; out = dir "/block_" NR ".zig"; next }
    inblk && /^```[[:space:]]*$/ { inblk = 0; close(out); next }
    inblk { print > out }
' "$readme"

blocks="$(find "$work" -name 'block_*.zig' 2>/dev/null | LC_ALL=C sort -t_ -k2 -n)"
if [ -z "$blocks" ]; then
    echo "  FAIL: no \`\`\`zig blocks found in $readme."
    exit 1
fi

# Compile blocks containing Client.open; skip standalone fragments. Supply the
# imports and locals established by the README prose.
compiled=0
for blk in $blocks; do
    line="$(basename "$blk" .zig | sed 's/^block_//')"
    body="$(cat "$blk")"

    case "$body" in
        *"Client.open"*) ;;
        *) continue ;;
    esac

    prog="$work/prog_${line}.zig"
    {
        echo 'const std = @import("std");'
        echo 'const agent = @import("agent");'
        echo 'const Allocator = std.mem.Allocator;'
        echo ''
        # Provide the tool fixtures introduced in the Usage prose.
        echo 'fn addNumbers(_: ?*anyopaque, arena: Allocator, _: std.json.Value) !agent.ToolResult {'
        echo '    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{@as(u8, 0)}) };'
        echo '}'
        echo 'const tools = [_]agent.Tool{.{ .name = "add", .description = "d", .input_schema = "{}", .handler = addNumbers }};'
        echo 'const servers = [_]agent.McpServer{.{ .name = "host", .tools = &tools }};'
        echo ''
        # Use the same main prologue as examples/demo.zig.
        echo 'pub fn main(init: std.process.Init) !void {'
        echo '    const io = init.io;'
        echo '    const gpa = init.gpa;'
        echo '    var buf: [64]u8 = undefined;'
        echo '    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);'
        echo '    const out = &stdout.interface;'
        printf '%s\n' "$body" | sed 's/^/    /'
        echo '}'
    } > "$prog"

    # Compile without running. Emit to a temporary file because the macOS linker
    # cannot write to /dev/null.
    if err="$(zig build-exe \
                --dep agent \
                -Mroot="$prog" \
                -Magent=src/agent.zig \
                --cache-dir "$work/zig-cache" \
                -femit-bin="$work/bin_${line}" 2>&1)"; then
        echo "  ok: \`\`\`zig block at $readme:$line compiles."
        compiled=$((compiled + 1))
    else
        echo "  FAIL: \`\`\`zig block at $readme:$line no longer compiles against src/agent.zig:"
        printf '%s\n' "$err" | sed 's/^/          /'
        echo "        (If README.md is mid-edit by someone else, re-run before"
        echo "         changing it — this gate does not edit the README.)"
        fail=1
    fi
done

if [ "$compiled" -eq 0 ] && [ "$fail" -eq 0 ]; then
    echo "  FAIL: no compilable usage block found — the '## Usage' example is gone or no longer calls Client.open."
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "docs-check: FAIL — README.md has drifted from the code."
    exit 1
fi
echo "docs-check: PASS — Layout table matches the tree and the usage example still compiles."
