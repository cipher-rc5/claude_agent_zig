#!/usr/bin/env bash
# scripts/docs-check.sh
# Mechanical README-vs-code drift gate. Run by `just docs-check`, which `just ci`
# depends on. Two independent checks, both fail-closed:
#
#   (a) layout — the "## Layout" table must list exactly the .zig files that
#       exist under src/, examples/ and tests/. No missing rows, no stale rows.
#   (b) usage  — every ```zig block in the README that looks like a full usage
#       program must still COMPILE against the current `agent` module. Blocks
#       are compiled, not run: this catches renamed fields, changed signatures
#       and removed methods, which is the drift class the docs keep hitting.
#
# Deterministic and offline. No network, no `claude` binary, no test execution.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

readme="README.md"
fail=0

if [ ! -f "$readme" ]; then
    echo "docs-check: FAIL — $readme not found."
    exit 1
fi

# ---------------------------------------------------------------- (a) layout
echo "docs-check: [layout] README '## Layout' table vs the real tree"

# Real tree: every .zig file under the three source dirs, sorted.
actual="$(find src examples tests -name '*.zig' -type f 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort)"

# Documented: first column of each table row inside the "## Layout" section,
# taking only `backticked` paths that end in .zig. The section runs from the
# "## Layout" heading to the next "## " heading.
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

# ----------------------------------------------------------------- (b) usage
echo "docs-check: [usage] README \`\`\`zig blocks compile against src/agent.zig"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Split the README into its ```zig blocks, one file per block, numbered by the
# line the fence opens on so failures point at the README.
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

# A block is a "usage program" if it calls into the client lifecycle. Fragment
# blocks (bare struct literals, single field assignments) are not compilable on
# their own and are skipped by design — they are checked by eye, not here.
# The prelude wraps a block in a main() with the imports and locals the README
# text establishes but does not repeat inside every fence.
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
        # Locals the Usage prose introduces before the fence.
        echo 'fn addNumbers(_: ?*anyopaque, arena: Allocator, _: std.json.Value) !agent.ToolResult {'
        echo '    return .{ .text = try std.fmt.allocPrint(arena, "{d}", .{@as(u8, 0)}) };'
        echo '}'
        echo 'const tools = [_]agent.Tool{.{ .name = "add", .description = "d", .input_schema = "{}", .handler = addNumbers }};'
        echo 'const servers = [_]agent.McpServer{.{ .name = "host", .tools = &tools }};'
        echo ''
        # Mirrors examples/demo.zig's own prologue, so the block is compiled
        # in the same shape a real caller would write it.
        echo 'pub fn main(init: std.process.Init) !void {'
        echo '    const io = init.io;'
        echo '    const gpa = init.gpa;'
        echo '    var buf: [64]u8 = undefined;'
        echo '    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);'
        echo '    const out = &stdout.interface;'
        # The block itself, indented so a stray top-level decl is a clear error.
        printf '%s\n' "$body" | sed 's/^/    /'
        echo '}'
    } > "$prog"

    # Compile only — the binary is emitted into the temp dir and never run,
    # so this stays fast and side-effect free. (-femit-bin=/dev/null is not
    # usable here: the linker cannot write to a device node on macOS.)
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
