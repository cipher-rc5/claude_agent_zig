#!/usr/bin/env python3
"""Synthetic protocol fixture, not a captured or version-certified CLI trace."""

import json
import sys


def read():
    line = sys.stdin.readline(65537)
    assert line.endswith("\n"), "missing or oversized frame"
    return json.loads(line)


def emit(value):
    print(json.dumps(value), flush=True)


def mcp(request_id, message_id, method, params=None):
    message = {"jsonrpc": "2.0", "id": message_id, "method": method}
    if params is not None:
        message["params"] = params
    emit({"type": "control_request", "request_id": request_id, "request": {
        "subtype": "mcp_message", "server_name": "fixture", "message": message,
    }})
    reply = read()["response"]
    assert reply["request_id"] == request_id and reply["subtype"] == "success"
    response = reply["response"]["mcp_response"]
    assert response["id"] == message_id and response["jsonrpc"] == "2.0"
    return response["result"]


def main():
    assert sys.argv[sys.argv.index("--resume") + 1] == "sanitized-session"
    initialization = read()
    assert initialization["type"] == "control_request"
    assert initialization["request"]["subtype"] == "initialize"
    assert initialization["request"]["sdkMcpServers"] == ["fixture"]
    assert "request_id" not in initialization["request"]
    emit({"type": "control_response", "response": {
        "subtype": "success", "request_id": initialization["request_id"], "response": {},
    }})
    assert read()["message"]["content"][0]["text"] == "fixture prompt"
    emit({"type": "system", "subtype": "init", "session_id": "sanitized-session"})
    interrupt = read()
    assert interrupt["type"] == "control_request"
    assert interrupt["request"]["subtype"] == "interrupt"
    assert "request_id" not in interrupt["request"]
    emit({"type": "control_response", "response": {
        "subtype": "success", "request_id": interrupt["request_id"], "response": {},
    }})
    listing = mcp("list", 1, "tools/list")
    assert [tool["name"] for tool in listing["tools"]] == ["echo"]
    call = mcp("call", "message-id", "tools/call", {"name": "echo", "arguments": {"n": 41}})
    assert call["content"] == [{"type": "text", "text": "42"}]
    for behavior in ("allow", "deny"):
        request_id = "permission-" + behavior
        emit({"type": "control_request", "request_id": request_id, "request": {
            "subtype": "can_use_tool", "tool_name": "fixture_" + behavior, "input": {"path": "sanitized"},
        }})
        reply = read()["response"]
        assert reply["request_id"] == request_id and reply["subtype"] == "success"
        decision = reply["response"]
        assert decision["behavior"] == behavior
        if behavior == "allow":
            assert decision["updatedInput"] == {"path": "sanitized"}
        else:
            assert decision["message"] == "fixture denial"
    emit({"type": "result", "result": "fixture complete", "session_id": "sanitized-session"})


if __name__ == "__main__":
    main()
