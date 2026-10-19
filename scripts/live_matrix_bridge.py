#!/usr/bin/env python3
"""Transparent real-CLI transport with bounded, whitelisted evidence."""

import copy
import json
import os
import signal
import subprocess
import sys
import threading
import time

from live_matrix import correlation_id, sanitize_message

MAX_LINE = 1024 * 1024
MAX_TRACE = 2 * 1024 * 1024


def main():
    binary = os.environ["LIVE_REAL_CLI"]
    scenario = os.environ["LIVE_SCENARIO"]
    nonce = os.environ["LIVE_NONCE"]
    args = sys.argv[1:]
    phase = "resume" if "--resume" in args else "seed" if scenario == "resume" else "main"
    fd = os.open(os.environ["LIVE_TRACE"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    log = os.fdopen(fd, "w")
    lock = threading.Lock()
    started = time.monotonic()
    failure = threading.Event()
    interrupts = 0
    text_characters = 0
    text_prefix = ""
    text_tail = ""
    end_marker_seen = False
    result_end_marker_seen = False

    def record(value):
        value.update(phase=phase, elapsed_ms=round((time.monotonic() - started) * 1000))
        line = json.dumps(value, separators=(",", ":")) + "\n"
        with lock:
            if os.fstat(log.fileno()).st_size + len(line.encode()) > MAX_TRACE:
                raise ValueError("sanitized trace exceeds 2 MiB")
            log.write(line)
            log.flush()

    def argument(flag):
        indices = [index for index, value in enumerate(args) if value == flag]
        if len(indices) != 1 or indices[0] + 1 >= len(args):
            raise ValueError("missing or repeated required CLI flag")
        return args[indices[0] + 1]

    record({"event": "client_start", "source": os.environ["LIVE_TRACE_SOURCE"], "resume": "--resume" in args, "scenario": scenario,
            "budget_threshold_usd": argument("--max-budget-usd"), "configured_max_turns": int(argument("--max-turns")),
            "tools_disabled": argument("--tools") == "", "settings_sources_empty": argument("--setting-sources") == "",
            "strict_empty_mcp": "--strict-mcp-config" in args and argument("--mcp-config") == '{"mcpServers":{}}',
            "hooks_disabled": json.loads(argument("--settings")).get("disableAllHooks") is True})
    child = subprocess.Popen([binary, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    reap_lock = threading.Lock()
    reaped = False

    def fail(error):
        failure.set()
        try:
            record({"event": "bridge_failure", "error_type": type(error).__name__})
        finally:
            with reap_lock:
                if not reaped:
                    try:
                        os.kill(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def send_stdin():
        nonlocal interrupts
        try:
            while line := sys.stdin.buffer.readline(MAX_LINE + 1):
                if len(line) > MAX_LINE or not line.endswith(b"\n"):
                    raise ValueError("oversized or incomplete SDK line")
                message = json.loads(line)
                if scenario == "interrupt_rejection" and message.get("type") == "control_request" and message.get("request", {}).get("subtype") == "interrupt":
                    interrupts += 1
                    if interrupts == 2:
                        message = copy.deepcopy(message)
                        request_id = message.get("request_id")
                        record({"event": "fault_injected", "original_subtype": "interrupt", "wire_subtype": "matrix_unsupported_interrupt", "request_id": correlation_id(request_id)})
                        message["request"]["subtype"] = "matrix_unsupported_interrupt"
                        line = (json.dumps(message) + "\n").encode()
                record({"direction": "sdk_to_cli", "message": sanitize_message(message, nonce)})
                child.stdin.write(line)
                child.stdin.flush()
            child.stdin.close()
        except BrokenPipeError:
            pass
        except BaseException as error:
            fail(error)

    sender = threading.Thread(target=send_stdin, daemon=True)
    sender.start()
    try:
        while line := child.stdout.readline(MAX_LINE + 1):
            if len(line) > MAX_LINE or not line.endswith(b"\n"):
                raise ValueError("oversized or incomplete CLI line")
            message = json.loads(line)
            if scenario == "interrupt":
                if message.get("type") == "stream_event":
                    delta = message.get("event", {}).get("delta", {})
                    text = delta.get("text", "") if delta.get("type") == "text_delta" else ""
                    if isinstance(text, str):
                        text_characters += len(text)
                        text_prefix = (text_prefix + text)[:128]
                        end_marker_seen = end_marker_seen or "MATRIX-END" in text_tail + text
                        text_tail = (text_tail + text)[-32:]
                if message.get("type") == "result":
                    result_end_marker_seen = "MATRIX-END" in str(message.get("result", ""))
            record({"direction": "cli_to_sdk", "message": sanitize_message(message, nonce)})
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError, ValueError, TypeError) as error:
        fail(error)
    while os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
        time.sleep(.01)
    with reap_lock:
        code = child.wait()
        reaped = True
    if scenario == "interrupt":
        numeric_prefix = "".join(character for character in text_prefix if character in "0123456789\n\r ,.-:")
        record({"event": "stream_summary", "text_characters": text_characters, "numeric_prefix": numeric_prefix,
                "end_marker_seen": end_marker_seen, "result_end_marker_seen": result_end_marker_seen})
    record({"event": "client_exit", "exit_code": code, "bridge_failed": failure.is_set()})
    log.close()
    return code if code >= 0 and not failure.is_set() else 1


if __name__ == "__main__":
    sys.exit(main())
