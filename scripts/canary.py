#!/usr/bin/env python3
"""Check CLI parser compatibility without a model request."""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

from processes import run

FLAGS = """--print --input-format --output-format --verbose --bare
--include-partial-messages --model --allowedTools --permission-mode
--permission-prompts --append-system-prompt --tools --setting-sources --add-dir
--plugin-dir --agents --disable-slash-commands --strict-mcp-config --mcp-config
--resume""".split()
SENTINEL = "--definitely-not-a-real-flag-xyz"


def check(root: Path, binary: str, strict: bool):
    if shutil.which(binary) is None:
        if strict:
            raise ValueError(f"'{binary}' is missing; strict compatibility cannot be skipped")
        print(f"canary: SKIP — '{binary}' is not on PATH")
        return
    options = (root / "src/options.zig").read_text()
    match = re.search(r'pub const min_cli_version = "(\d+\.\d+\.\d+)";', options)
    if match is None:
        raise ValueError("cannot read the CLI version floor")
    floor = tuple(map(int, match[1].split(".")))
    code, version = run([binary, "--version"], timeout=15, cwd=root)
    installed = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:\s|$)", version)
    if code or installed is None or tuple(map(int, installed.groups())) < floor:
        raise ValueError(f"unsupported CLI version response: {version.strip()!r}")
    code, help_text = run([binary, "--help"], timeout=15, cwd=root)
    if code:
        raise ValueError(f"--help failed ({code}): {help_text.strip()}")
    for flag in FLAGS:
        if not re.search(r"(?:^|\s)" + re.escape(flag) + r"(?:[\s,<=]|$)", help_text):
            raise ValueError(f"--help does not advertise {flag}")
    mode_fn = options.split("pub fn cliName", 1)[1].split("};", 1)[0]
    modes = re.findall(r'=>\s*"([^"]+)"', mode_fn)
    if not modes:
        raise ValueError("cannot read PermissionMode.cliName")
    mode_help = re.search(r"--permission-mode[\s\S]{0,1000}", help_text)
    if mode_help is None or any(f'"{mode}"' not in mode_help[0] for mode in modes):
        raise ValueError("--permission-mode choices differ from PermissionMode.cliName")
    # Require sentinel rejection to distinguish flag acceptance from unrelated failures.
    for flags in ([], ["--max-turns", "3"], ["--permission-prompt-tool", "stdio"]):
        code, output = run([binary, "--print", *flags, SENTINEL], timeout=15, cwd=root)
        diagnostic = re.search(r"unknown (?:option|argument)[^\n]*" + re.escape(SENTINEL), output, re.I)
        if code == 0 or diagnostic is None:
            raise ValueError(f"parser probe {flags!r} did not reject the sentinel: {output.strip()!r}")
        for flag in flags[::2]:
            if re.search(r"unknown (?:option|argument)[^\n]*" + re.escape(flag), output, re.I):
                raise ValueError(f"parser rejected {flag}")
    print(f"canary: PASS — {version.strip()}; version, help, and parser probes verified (no model use)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        check(args.root, os.environ.get("CLAUDE_BIN", "claude"), args.strict)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"canary: FAIL — {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
