#!/usr/bin/env python3
"""Synthetic CLI for live-matrix harness tests; never represents live evidence."""

import json
import os
from pathlib import Path
import sys
import time


PENDING = []


def read_wire():
    line = sys.stdin.readline()
    assert line, "missing SDK frame"
    return json.loads(line)


def read():
    return PENDING.pop(0) if PENDING else read_wire()


def read_control(subtype):
    envelope = read()
    assert envelope.get("type") == "control_request", "missing control envelope"
    request = envelope.get("request", {})
    assert request.get("subtype") == subtype, "unexpected control subtype"
    assert isinstance(envelope.get("request_id"), str) and envelope["request_id"], "request_id must be at envelope top level"
    assert "request_id" not in request, "nested request_id is not a valid outbound control envelope"
    return envelope


def emit(value):
    print(json.dumps(value), flush=True)


def success(request_id):
    emit({"type": "control_response", "response": {"subtype": "success", "request_id": request_id, "response": {}}})


def mcp(request_id, method, params=None):
    rpc = {"jsonrpc": "2.0", "id": "rpc-" + request_id, "method": method}
    if params is not None:
        rpc["params"] = params
    emit({"type": "control_request", "request_id": request_id, "request": {"subtype": "mcp_message", "server_name": "matrix", "message": rpc}})
    while True:
        reply = read_wire()
        if reply.get("type") == "control_response" and reply["response"]["request_id"] == request_id:
            return reply["response"]["response"]["mcp_response"]["result"]
        PENDING.append(reply)


def main():
    if sys.argv[1:] == ["--version"]:
        print("99.0.0 (Claude Code)")
        return
    if sys.argv[1:] == ["auth", "status", "--json"]:
        print(json.dumps({"loggedIn": True, "authMethod": "api_key", "email": "credential-do-not-record@example.invalid"}))
        return
    scenario = os.environ["LIVE_SCENARIO"]
    nonce = os.environ["LIVE_NONCE"]
    initialization = read_control("initialize")
    success(initialization["request_id"])
    is_interrupt = scenario in ("interrupt", "interrupt_rejection")
    if not is_interrupt:
        listed = mcp("listing", "tools/list")
        assert listed["tools"][0]["name"] == "probe"
    if scenario == "interrupt_rejection":
        idle = read_control("interrupt")
        success(idle["request_id"])
        invalid = read_control("matrix_unsupported_interrupt")
        emit({"type": "control_response", "response": {"subtype": "error", "request_id": invalid["request_id"], "error": "Unsupported control request: matrix_unsupported_interrupt"}})
        assert sys.stdin.readline() == ""
        return
    prompt = read()["message"]["content"][0]["text"]
    resumed = "--resume" in sys.argv
    session_id = sys.argv[sys.argv.index("--resume") + 1] if resumed else sys.argv[sys.argv.index("--session-id") + 1]
    emit({"type": "system", "subtype": "init", "session_id": session_id, "tools": [] if is_interrupt else ["mcp__matrix__probe"], "cwd": "/private/do-not-record", "apiKeySource": "do-not-record", "mcp_servers": [] if is_interrupt else [{"name": "matrix", "status": "connected"}]})
    if os.environ.get("LIVE_MATRIX_FIXTURE_HOLD") == "1":
        project = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "projects" / "synthetic-disposable-cwd"
        project.mkdir(parents=True, exist_ok=True)
        (project / (session_id + ".jsonl")).write_text("synthetic owned session")
        Path(os.environ["LIVE_MATRIX_FIXTURE_READY"]).touch()
        time.sleep(30)
    if scenario == "interrupt":
        emit({"type": "stream_event", "event": {"type": "message_start"}})
        emit({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "1\n2\n3\n4\n5\n"}}})
        interruption = read_control("interrupt")
        success(interruption["request_id"])
    elif scenario == "resume" and not resumed:
        assert nonce in prompt
        Path("seed-marker").write_text(nonce)
    else:
        value = Path("seed-marker").read_text() if scenario == "resume" else "original"
        if scenario == "resume":
            assert nonce not in prompt
        arguments = {"value": value, "nonce": "resume-proof" if scenario == "resume" else nonce}
        emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "tool-1", "name": "mcp__matrix__probe", "input": arguments}]}})
        denied = False
        if scenario.startswith("permission_"):
            emit({"type": "control_request", "request_id": "permission", "request": {"subtype": "can_use_tool", "tool_name": "mcp__matrix__probe", "input": arguments}})
            decision = read()["response"]["response"]
            denied = decision["behavior"] == "deny"
            if not denied:
                arguments = decision["updatedInput"]
        if not denied:
            called = mcp("call", "tools/call", {"name": "probe", "arguments": arguments})
            assert called["content"][0]["text"] == "matrix-tool-result"
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "tool-1", "is_error": denied}]}})
    canceled = scenario == "interrupt" and os.environ.get("LIVE_MATRIX_FIXTURE_CANCEL") == "1"
    emit({"type": "result", "subtype": "error_during_execution" if canceled else "success", "is_error": canceled,
          "terminal_reason": "aborted_streaming" if canceled else "completed", "result": "arbitrary model text deliberately ignored",
          "session_id": session_id, "num_turns": 1, "total_cost_usd": 0.001})
    assert sys.stdin.readline() == ""
    if canceled:
        sys.exit(1)


if __name__ == "__main__":
    main()
