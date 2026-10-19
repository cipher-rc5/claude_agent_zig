#!/usr/bin/env python3
"""Run the public client against a bounded synthetic protocol fixture offline."""

import os
from pathlib import Path
import shlex
import sys
import tempfile

from processes import run

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="claude-compatibility-") as temporary:
    work = Path(temporary)
    for source, executable in (("compatibility.zig", "compatibility"), ("live_compatibility.zig", "live")):
        code, output = run([
            "zig", "build-exe", "--dep", "agent", f"-Mroot={root / 'scripts' / source}",
            f"-Magent={root / 'src/agent.zig'}", f"-femit-bin={work / executable}",
        ], cwd=root, timeout=120)
        if code:
            raise RuntimeError(f"compatibility runner {source} did not compile: {output}")
    stub = work / "cli"
    stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(root / "scripts/compatibility_fixture.py")) + ' "$@"\n')
    stub.chmod(0o755)
    code, output = run([str(work / "compatibility")], env=dict(os.environ, COMPATIBILITY_CLI=str(stub)), timeout=20)
    if code:
        raise RuntimeError(f"compatibility fixture failed ({code}): {output}")
print("compatibility: PASS — synthetic initialization, MCP list/call, permissions, interrupt, resume; no live CLI/model")
