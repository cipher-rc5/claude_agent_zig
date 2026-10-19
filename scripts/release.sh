#!/usr/bin/env bash
# Builds reviewed local artifacts without creating a tag or publishing them.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
fail() { echo "release: REFUSED — $*" >&2; exit 1; }
[ $# -eq 1 ] || { echo 'usage: scripts/release.sh <version>' >&2; exit 2; }
version="$1"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || fail 'invalid version'
[ -z "$(git status --porcelain)" ] || fail 'working tree must be clean'
python3 - "$version" <<'PY'
import pathlib, re, sys
version = sys.argv[1]
manifest = pathlib.Path('build.zig.zon').read_text()
assert re.search(r'\.version\s*=\s*"' + re.escape(version) + r'"', manifest), 'manifest version mismatch'
assert re.search(r'^## \[' + re.escape(version) + r'\]', pathlib.Path('CHANGELOG.md').read_text(), re.M), 'missing changelog heading'
PY
if existing="$(git rev-parse -q --verify "refs/tags/v$version^{commit}" 2>/dev/null)"; then
    [ "$existing" = "$(git rev-parse HEAD)" ] || fail "v$version already names another commit"
fi
command -v just >/dev/null || fail "'just' is required"
command -v zig >/dev/null || fail "'zig' is required"
echo 'release: running extended local checks and strict CLI parser compatibility'
just ci-full || fail 'strict gate failed; artifacts were not created'
python3 scripts/release_artifacts.py create "$version"
python3 scripts/release_artifacts.py verify "$version"
printf '\nrelease: review dist/ before deliberately tagging or publishing. Suggested tag:\n'
printf '    git tag -a v%s -m "claude_agent_zig %s"\n' "$version" "$version"
