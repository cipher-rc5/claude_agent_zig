#!/usr/bin/env python3
"""Verify build-run argument forwarding using an offline CLI stub."""

import os
from pathlib import Path
import tempfile

from processes import run

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="claude-demo-smoke-") as temporary:
    work = Path(temporary)
    capture = work / "capture"
    stub = work / "cli"
    stub.write_text('''#!/usr/bin/env python3
import json, os, sys
initialization = json.loads(sys.stdin.readline())
assert initialization['request']['subtype'] == 'initialize'
turn = json.loads(sys.stdin.readline())
with open(os.environ['SMOKE_CAPTURE'], 'w') as capture:
    capture.write(turn['message']['content'][0]['text'])
print('{"type":"result","result":"smoke","session_id":"fixture"}', flush=True)
''')
    stub.chmod(0o755)
    env = dict(os.environ, CLAUDE_BIN=str(stub), SMOKE_CAPTURE=str(capture))
    prompt = 'forwarded spaces, "quotes", $literal and unicode: λ'
    code, output = run(["zig", "build", "run", "--", prompt], cwd=root, env=env, timeout=120)
    if code or not capture.exists() or capture.read_text() != prompt:
        raise RuntimeError(f"demo forwarding failed ({code}): {output}")
print("demo-smoke: PASS — build-run preserved the complete prompt")
