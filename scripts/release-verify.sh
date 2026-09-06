#!/usr/bin/env bash
# scripts/release-verify.sh
# Checks what scripts/release.sh left in dist/. Run by `just release-verify
# <version>`. Verifies SHA256SUMS against the files it names and, when
# RELEASE_ALLOWED_SIGNERS points at an ssh allowed_signers file, the signature
# over SHA256SUMS too. Without that variable the signature is reported as not
# checked rather than as valid: an unchecked signature must never read as a
# verified one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
    echo "release-verify: FAIL — $*" >&2
    exit 1
}

[ $# -eq 1 ] || { echo "usage: scripts/release-verify.sh <version>" >&2; exit 2; }
version="$1"
name="claude_agent_zig-$version"

[ -d dist ] || fail "no dist/ directory; run 'just release $version' first"
for f in "$name.tar.gz" "$name.cdx.json" SHA256SUMS; do
    [ -f "dist/$f" ] || fail "dist/$f is missing"
done

if command -v sha256sum >/dev/null 2>&1; then
    sum_cmd=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    sum_cmd=(shasum -a 256)
else
    fail "neither sha256sum nor shasum is on PATH"
fi

echo "release-verify: checking dist/SHA256SUMS"
(cd dist && "${sum_cmd[@]}" -c SHA256SUMS) || fail "a checksum did not match"

# Both artefacts must be covered, not merely whichever lines happen to exist.
for f in "$name.tar.gz" "$name.cdx.json"; do
    f_re="$(printf '%s' "$f" | sed 's/[.]/\\./g')"
    grep -qE -- "[[:space:]]\*?${f_re}\$" dist/SHA256SUMS || fail "dist/SHA256SUMS does not cover $f"
done

echo "release-verify: checking the archive prefix"
first="$(tar -tzf "dist/$name.tar.gz" | head -n 1)"
case "$first" in
    "$name/"*) ;;
    *) fail "archive entries start with '$first', expected '$name/'" ;;
esac

echo "release-verify: checking the SBOM names $version"
grep -q "\"version\": \"$version\"" "dist/$name.cdx.json" || fail "SBOM does not carry version $version"
grep -q '"specVersion": "1.5"' "dist/$name.cdx.json" || fail "SBOM is not CycloneDX 1.5"

if [ -n "${RELEASE_ALLOWED_SIGNERS:-}" ]; then
    [ -r "$RELEASE_ALLOWED_SIGNERS" ] || fail "RELEASE_ALLOWED_SIGNERS=$RELEASE_ALLOWED_SIGNERS is not readable"
    [ -f dist/SHA256SUMS.sig ] || fail "RELEASE_ALLOWED_SIGNERS is set but dist/SHA256SUMS.sig is missing"
    # The principal defaults to the first identity in the allowed_signers
    # file, which is the usual single-owner layout; RELEASE_SIGNER_IDENTITY
    # overrides it when the file lists several.
    identity="${RELEASE_SIGNER_IDENTITY:-$(grep -v '^[[:space:]]*#' "$RELEASE_ALLOWED_SIGNERS" | awk 'NF { print $1; exit }')}"
    [ -n "$identity" ] || fail "could not determine a signer identity from $RELEASE_ALLOWED_SIGNERS"
    echo "release-verify: checking dist/SHA256SUMS.sig against $RELEASE_ALLOWED_SIGNERS as '$identity'"
    ssh-keygen -Y verify -f "$RELEASE_ALLOWED_SIGNERS" -I "$identity" -n file \
        -s dist/SHA256SUMS.sig < dist/SHA256SUMS || fail "signature did not verify"
    echo "release-verify: PASS — sums match and the signature verifies."
else
    if [ -f dist/SHA256SUMS.sig ]; then
        echo "release-verify: dist/SHA256SUMS.sig is present but NOT CHECKED — set RELEASE_ALLOWED_SIGNERS=<allowed_signers file> to verify it."
    else
        echo "release-verify: no signature present (release.sh ran without RELEASE_SIGNING_KEY)."
    fi
    echo "release-verify: PASS — sums match; signature not checked."
fi
