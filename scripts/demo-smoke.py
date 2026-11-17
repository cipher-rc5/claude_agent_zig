#!/usr/bin/env python3
"""Verify build-run argument forwarding using an offline CLI stub."""

import os
import json
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
    json.dump({'prompt': turn['message']['content'][0]['text'], 'args': sys.argv[1:]}, capture)
if '--include-partial-messages' in sys.argv:
    print(json.dumps({'type': 'stream_event', 'event': {'delta': {'type': 'text_delta', 'text': 'partial output'}}}), flush=True)
print('{"type":"result","result":"smoke","session_id":"fixture"}', flush=True)
''')
    stub.chmod(0o755)
    env = dict(os.environ, CLAUDE_BIN=str(stub), SMOKE_CAPTURE=str(capture))
    prompt = 'forwarded spaces, "quotes", $literal and unicode: λ'
    for mode in ("auto", "stream", "buffered", "final"):
        env["AGENT_OUTPUT"] = mode
        code, output = run(["zig", "build", "run", "--", prompt], cwd=root, env=env, timeout=120)
        recorded = json.loads(capture.read_text()) if capture.exists() else {}
        if (code or recorded.get("prompt") != prompt or "smoke" not in output or
                ("--include-partial-messages" in recorded.get("args", [])) != (mode != "final") or
                ("partial output" in output) != (mode != "final")):
            raise RuntimeError(f"demo {mode} output/forwarding failed ({code}): {output}")
print("demo-smoke: PASS — prompt forwarding and all output modes")
