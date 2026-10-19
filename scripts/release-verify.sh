#!/usr/bin/env bash
# Defaults to integrity verification against HEAD; trusted signers authenticate it.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$repo_root/scripts/release_artifacts.py" verify "$@"
