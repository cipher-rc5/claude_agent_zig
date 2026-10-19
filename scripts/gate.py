#!/usr/bin/env python3
"""Reproducible extended local gate; no network, model use, or publication."""

import os
from pathlib import Path
import subprocess
import sys

from processes import run


def main():
    if sys.platform != "darwin":
        print("ci-extended: FAIL — the supported validation host is macOS", file=sys.stderr)
        return 1
    root = Path(__file__).resolve().parent.parent
    commands = [
        ["just", "ci"],
        ["zig", "build", "test", "-Doptimize=ReleaseFast", "--test-timeout", "10s"],
        ["python3", "-B", "-m", "unittest", "discover", "-s", "scripts", "-p", "*_test.py", "-v"],
        ["zig", "build", "docs"],
        ["zig", "build", "examples-check"],
        ["python3", "scripts/compatibility.py"],
        ["zig", "build", "bench", "-Doptimize=ReleaseFast", "--", "20", "normal", "1"],
        ["python3", "scripts/demo-smoke.py"],
    ]
    commands[0:0] = [["bash", "-n", str(file)] for file in sorted((root / "scripts").glob("*.sh"))]
    commands[0:0] = [["sh", "-n", str(file)] for file in sorted((root / ".githooks").glob("pre-*"))]
    try:
        timeout = float(os.environ.get("LOCAL_GATE_TIMEOUT_SECONDS", "300"))
        if not 1 <= timeout <= 3600:
            raise ValueError("LOCAL_GATE_TIMEOUT_SECONDS must be between 1 and 3600")
        for command in commands:
            print("ci-extended: " + " ".join(command), flush=True)
            code, output = run(command, cwd=root, timeout=timeout)
            print(output, end="", flush=True)
            if code:
                raise RuntimeError(f"command exited {code}")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"ci-extended: FAIL — {error}", file=sys.stderr)
        return 1
    print("ci-extended: PASS — native macOS checks; no live model use")
    return 0


if __name__ == "__main__":
    sys.exit(main())
