#!/usr/bin/env bash
# scripts/release.sh
# Local release pipeline. Run by `just release <version>`. Produces, in dist/:
#
#   claude_agent_zig-<version>.tar.gz    `git archive` of HEAD
#   claude_agent_zig-<version>.cdx.json  minimal CycloneDX 1.5 SBOM
#   SHA256SUMS                           over the two files above
#   SHA256SUMS.sig                       ssh-keygen signature, when
#                                        RELEASE_SIGNING_KEY is set
#
# It refuses to run on a dirty tree, on a version that does not match
# build.zig.zon, or on a version CHANGELOG.md has no heading for, and it runs
# `just ci-full` before archiving anything. It never tags, commits or pushes:
# it prints the `git tag` command at the end, and running it is the owner's
# decision, made after looking at what is in dist/.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
    echo "usage: scripts/release.sh <version>    (e.g. 0.1.0; must match build.zig.zon)" >&2
    exit 2
}
fail() {
    echo "release: REFUSED — $*" >&2
    exit 1
}

[ $# -eq 1 ] || usage
version="$1"
printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' \
    || fail "'$version' is not a semantic version"

# ------------------------------------------------------------- preconditions
if [ -n "$(git status --porcelain)" ]; then
    git status --short >&2
    fail "the working tree is dirty; a release is cut from a commit, not from disk"
fi

zon_version="$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon | head -n 1)"
[ -n "$zon_version" ] || fail "could not read .version out of build.zig.zon"
[ "$zon_version" = "$version" ] \
    || fail "build.zig.zon says .version = \"$zon_version\", not \"$version\"; bump the manifest first"

grep -qE "^## \[$(printf '%s' "$version" | sed 's/[.]/\\./g')\]" CHANGELOG.md \
    || fail "CHANGELOG.md has no '## [$version]' heading; move the [Unreleased] notes under one first"

tag="v$version"
if existing="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null)"; then
    head_sha="$(git rev-parse HEAD)"
    [ "$existing" = "$head_sha" ] \
        || fail "tag $tag already exists at $(git rev-parse --short "$existing"), not at HEAD ($(git rev-parse --short "$head_sha"))"
    echo "release: note — $tag already points at HEAD; rebuilding its artefacts."
fi

command -v just >/dev/null 2>&1 || fail "'just' is not on PATH and the gate is 'just ci-full'"
command -v zig >/dev/null 2>&1 || fail "'zig' is not on PATH"

if command -v sha256sum >/dev/null 2>&1; then
    sum_cmd=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    sum_cmd=(shasum -a 256)
else
    fail "neither sha256sum nor shasum is on PATH"
fi

# --------------------------------------------------------------------- gate
echo "release: running the full gate (just ci-full) for $tag"
just ci-full || fail "just ci-full failed; nothing was written to dist/"

# ---------------------------------------------------------------- artefacts
name="claude_agent_zig-$version"
mkdir -p dist
rm -f "dist/$name.tar.gz" "dist/$name.cdx.json" dist/SHA256SUMS dist/SHA256SUMS.sig

echo "release: archiving HEAD ($(git rev-parse --short HEAD)) -> dist/$name.tar.gz"
git archive --format=tar.gz --prefix="$name/" -o "dist/$name.tar.gz" HEAD

tarball_sha="$("${sum_cmd[@]}" "dist/$name.tar.gz" | awk '{print $1}')"
zig_version="$(zig version)"
commit="$(git rev-parse HEAD)"
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
serial="$( (uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid) | tr 'A-F' 'a-f')"
bom_ref="pkg:github/cipher-rc5/claude_agent_zig@$tag"

# One component and no dependency edges, which is the true shape of the
# package: build.zig.zon declares `.dependencies = .{}` and std is part of the
# toolchain, recorded as a property rather than as a component.
echo "release: writing dist/$name.cdx.json"
cat > "dist/$name.cdx.json" <<JSON
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:$serial",
  "version": 1,
  "metadata": {
    "timestamp": "$stamp",
    "tools": [
      { "name": "scripts/release.sh", "version": "$commit" }
    ],
    "component": {
      "type": "library",
      "name": "claude_agent_zig",
      "version": "$version"
    }
  },
  "components": [
    {
      "type": "library",
      "bom-ref": "$bom_ref",
      "name": "claude_agent_zig",
      "version": "$version",
      "description": "Claude Agent SDK client for Zig: drives the claude CLI over stream-json.",
      "licenses": [
        { "expression": "LicenseRef-Proprietary" }
      ],
      "purl": "$bom_ref",
      "hashes": [
        { "alg": "SHA-256", "content": "$tarball_sha" }
      ],
      "externalReferences": [
        { "type": "vcs", "url": "https://github.com/cipher-rc5/claude_agent_zig" }
      ],
      "properties": [
        { "name": "zig:version", "value": "$zig_version" },
        { "name": "zig:minimum_zig_version", "value": "$(sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon | head -n 1)" },
        { "name": "git:commit", "value": "$commit" },
        { "name": "dependencies", "value": "none: build.zig.zon declares .dependencies = .{}; only the Zig standard library is used" }
      ]
    }
  ],
  "dependencies": [
    { "ref": "$bom_ref", "dependsOn": [] }
  ]
}
JSON

# Relative names, so `shasum -c` / `sha256sum -c` work from inside dist/.
echo "release: writing dist/SHA256SUMS"
(cd dist && "${sum_cmd[@]}" "$name.tar.gz" "$name.cdx.json" > SHA256SUMS)
cat dist/SHA256SUMS

# ---------------------------------------------------------------- signature
if [ -n "${RELEASE_SIGNING_KEY:-}" ]; then
    [ -r "$RELEASE_SIGNING_KEY" ] || fail "RELEASE_SIGNING_KEY=$RELEASE_SIGNING_KEY is not readable"
    echo "release: signing dist/SHA256SUMS with $RELEASE_SIGNING_KEY"
    ssh-keygen -Y sign -f "$RELEASE_SIGNING_KEY" -n file dist/SHA256SUMS
    echo "release: wrote dist/SHA256SUMS.sig"
else
    echo "release: signing SKIPPED — set RELEASE_SIGNING_KEY=<path to an ssh private key> to sign SHA256SUMS."
fi

# ------------------------------------------------------------------- output
echo ""
echo "release: dist/ is ready for $tag:"
ls -l dist | sed 's/^/  /'
echo ""
echo "release: this script does not tag. Tagging is the owner's decision; when"
echo "         dist/ looks right, run:"
echo ""
echo "    git tag -a $tag -m \"claude_agent_zig $version\""
echo ""
echo "         and then push the tag deliberately with 'git push origin $tag'."
echo "         Verify what was built at any time with 'just release-verify $version'."
