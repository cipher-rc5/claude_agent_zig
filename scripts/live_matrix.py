"""Bounded, opt-in live CLI semantics with sanitized evidence."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

from processes import run

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SCENARIOS = ("mcp", "permission_allow", "permission_deny", "permission_replace", "interrupt", "interrupt_rejection", "resume")
SCENARIOS = DEFAULT_SCENARIOS
CLIENTS = {name: (2 if name == "resume" else 1) for name in SCENARIOS}
TURNS = {"mcp": 2, "permission_allow": 2, "permission_deny": 2, "permission_replace": 2, "interrupt": 1, "interrupt_rejection": 0, "resume": 3}
SAFE_VALUES = {"original", "replacement", "resume-proof", "matrix-tool-result", "matrix deliberate denial; do not retry", "matrix unexpected permission input"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fingerprint(value):
    return "sha256:" + hashlib.sha256(str(value).encode()).hexdigest()[:16]


def correlation_id(value):
    return None if value is None else fingerprint(json.dumps(value, sort_keys=True, separators=(",", ":")))


def protocol_enum(value, allowed):
    return value if value in allowed else fingerprint(value)


def safe_scalar(value, nonce):
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        if value in SAFE_VALUES or value == nonce:
            return value
        return fingerprint(value)
    return "<non-scalar>"


def safe_arguments(value, nonce):
    if not isinstance(value, dict):
        return {"shape": type(value).__name__}
    return {key: safe_scalar(value[key], nonce) for key in ("value", "nonce") if key in value}


def safe_tool_name(name):
    return name if name == "mcp__matrix__probe" else fingerprint(name)


def sanitize_message(message, nonce):
    """Retain protocol facts and generated fixture values, never arbitrary text."""
    kind = message.get("type")
    result = {"type": kind if kind in ("system", "assistant", "user", "result", "stream_event", "control_request", "control_response", "sdk_control_request") else fingerprint(kind)}
    if message.get("session_id"):
        result["session_id"] = fingerprint(message["session_id"])
    if kind == "system":
        result["subtype"] = message.get("subtype") if message.get("subtype") in ("init", "status", "api_retry") else fingerprint(message.get("subtype"))
        if message.get("subtype") == "init":
            result["tools"] = [safe_tool_name(name) for name in message.get("tools", [])]
            result["mcp_servers"] = [{"name": server.get("name") if server.get("name") == "matrix" else fingerprint(server.get("name")), "status": server.get("status") if server.get("status") in ("connected", "failed", "pending", "disabled") else fingerprint(server.get("status"))} for server in message.get("mcp_servers", []) if isinstance(server, dict)]
    elif kind in ("control_request", "sdk_control_request"):
        request = message.get("request", {})
        result["request_id"] = correlation_id(message.get("request_id"))
        result["envelope_id_present"] = "request_id" in message
        result["nested_id_present"] = "request_id" in request
        subtype = request.get("subtype")
        result["request"] = {"subtype": subtype if subtype in ("initialize", "interrupt", "mcp_message", "can_use_tool", "matrix_unsupported_interrupt") else fingerprint(subtype)}
        target = result["request"]
        if subtype == "initialize":
            target["sdkMcpServers"] = [name if name == "matrix" else fingerprint(name) for name in request.get("sdkMcpServers", [])]
            target["skills"] = [fingerprint(name) for name in request["skills"]] if isinstance(request.get("skills"), list) else None
        if subtype == "can_use_tool":
            target["tool_name"] = safe_tool_name(request.get("tool_name"))
            target["input"] = safe_arguments(request.get("input"), nonce)
        if subtype == "mcp_message":
            target["server_name"] = request.get("server_name") if request.get("server_name") == "matrix" else fingerprint(request.get("server_name"))
            rpc = request.get("message", {})
            method = rpc.get("method")
            target["message"] = {"method": method if method in ("initialize", "notifications/initialized", "tools/list", "tools/call") else fingerprint(method), "id": correlation_id(rpc.get("id"))}
            if method == "tools/call":
                params = rpc.get("params", {})
                target["message"]["params"] = {"name": params.get("name") if params.get("name") == "probe" else fingerprint(params.get("name")), "arguments": safe_arguments(params.get("arguments"), nonce)}
    elif kind == "control_response":
        response = message.get("response", {})
        result["response"] = {"subtype": response.get("subtype") if response.get("subtype") in ("success", "error") else fingerprint(response.get("subtype")), "request_id": correlation_id(response.get("request_id"))}
        if "error" in response:
            error = response["error"]
            result["response"]["error_present"] = bool(error)
            result["response"]["error_fingerprint"] = fingerprint(error)
            result["response"]["unsupported_fault_named"] = "matrix_unsupported_interrupt" in str(error)
        body = response.get("response")
        if isinstance(body, dict):
            if "behavior" in body:
                result["response"]["response"] = {"behavior": protocol_enum(body.get("behavior"), ("allow", "deny"))}
                if "updatedInput" in body:
                    result["response"]["response"]["updatedInput"] = safe_arguments(body["updatedInput"], nonce)
                if "message" in body:
                    result["response"]["response"]["message"] = safe_scalar(body["message"], nonce)
            if isinstance(body.get("mcp_response"), dict):
                rpc = body["mcp_response"]
                safe_rpc = {"id": correlation_id(rpc.get("id")), "jsonrpc": protocol_enum(rpc.get("jsonrpc"), ("2.0",))}
                if "error" in rpc:
                    safe_rpc["error"] = {"code": rpc["error"].get("code") if isinstance(rpc["error"].get("code"), int) else fingerprint(rpc["error"].get("code"))}
                if isinstance(rpc.get("result"), dict):
                    rpc_result = rpc["result"]
                    safe_rpc["result"] = {}
                    if "tools" in rpc_result:
                        safe_rpc["result"]["tools"] = [{"name": tool.get("name") if tool.get("name") == "probe" else fingerprint(tool.get("name"))} for tool in rpc_result["tools"]]
                    if "content" in rpc_result:
                        safe_rpc["result"]["content"] = [{"type": protocol_enum(block.get("type"), ("text",)), "text": safe_scalar(block.get("text"), nonce)} for block in rpc_result["content"] if isinstance(block, dict)]
                    if "isError" in rpc_result:
                        safe_rpc["result"]["isError"] = rpc_result["isError"] if isinstance(rpc_result["isError"], bool) else fingerprint(rpc_result["isError"])
                result["response"]["response"] = {"mcp_response": safe_rpc}
    elif kind in ("assistant", "user"):
        body = message.get("message", {})
        content = body.get("content", []) if isinstance(body, dict) else []
        blocks = []
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    blocks.append({"type": "tool_use", "id": correlation_id(block.get("id")), "name": safe_tool_name(block.get("name")), "input": safe_arguments(block.get("input"), nonce)})
                elif block.get("type") == "tool_result":
                    blocks.append({"type": "tool_result", "tool_use_id": correlation_id(block.get("tool_use_id")), "is_error": bool(block.get("is_error", False))})
        result["message"] = {"content": blocks}
    elif kind == "stream_event":
        event = message.get("event", {})
        result["event"] = {"type": event.get("type") if event.get("type") in ("message_start", "message_stop", "content_block_start", "content_block_delta", "content_block_stop", "message_delta") else fingerprint(event.get("type"))}
    elif kind == "result":
        if "terminal_reason" in message:
            result["terminal_reason"] = protocol_enum(message["terminal_reason"], (None, "completed", "aborted_streaming", "aborted_tools", "api_error", "max_turns", "max_budget", "max_budget_usd", "max_structured_output_retries"))
        for key in ("subtype", "is_error", "num_turns", "total_cost_usd", "duration_ms"):
            if key in message:
                value = message[key]
                result[key] = value if isinstance(value, (int, float, bool)) or key == "subtype" and value in ("success", "error_max_turns", "error_during_execution", "error_max_budget_usd", "error_max_structured_output_retries") else fingerprint(value)
    return result


class ScenarioAssertionError(ValueError):
    def __init__(self, message, assertions):
        super().__init__(message)
        self.assertions = assertions


def matching_control(trace, direction, subtype):
    return [dict(record["message"], _phase=record.get("phase")) for record in trace if record.get("direction") == direction and record.get("message", {}).get("type") in ("control_request", "sdk_control_request") and record["message"].get("request", {}).get("subtype") == subtype]


def responses(trace, direction):
    return {(record.get("phase"), record["message"]["response"].get("request_id")): record["message"]["response"] for record in trace if record.get("direction") == direction and record.get("message", {}).get("type") == "control_response"}


def assert_scenario(scenario, trace, reports, nonce):
    """Assert both wire correlation and SDK-observed effects for a real CLI."""
    observed = []

    def check(condition, name):
        observed.append({"assertion": name, "passed": bool(condition)})
        if not condition:
            raise ScenarioAssertionError(f"{scenario}: {name}", observed)

    clients = [record for record in trace if record.get("event") == "client_start"]
    check(len(clients) == CLIENTS[scenario], "exact expected CLI client count")
    check(all(0 < Decimal(client["budget_threshold_usd"]) <= Decimal("0.05") and 1 <= client["configured_max_turns"] <= 2 for client in clients), "each CLI client has explicit bounded budget threshold and turns")
    check(all(client.get("tools_disabled") and client.get("settings_sources_empty") and client.get("strict_empty_mcp") and client.get("hooks_disabled") for client in clients), "each CLI client disables unrelated host tools and configuration")
    initializations = matching_control(trace, "sdk_to_cli", "initialize")
    cli_responses = responses(trace, "cli_to_sdk")
    check(len(initializations) == CLIENTS[scenario], "each public Client sent initialization")
    outbound = [record["message"] for record in trace if record.get("direction") == "sdk_to_cli" and record.get("message", {}).get("type") == "control_request"]
    check(all(request.get("envelope_id_present") is True and request.get("nested_id_present") is False for request in outbound), "SDK control request IDs are envelope fields without nested duplicates")
    check(all(cli_responses.get((request.get("_phase"), request.get("request_id")), {}).get("subtype") == "success" for request in initializations), "CLI accepted correlated SDK initialization")
    completed = [record for record in reports if record.get("event") == "scenario_complete"]
    check(len(completed) == 1 and completed[0].get("scenario") == scenario, "SDK scenario completed its semantic checks")
    sessions = [record for record in reports if record.get("event") == "session_complete"]
    check(len(sessions) == CLIENTS[scenario] and all(record.get("initialization") == "accepted" for record in sessions), "public status reports initialization accepted")
    tool_calls = [record for record in reports if record.get("event") == "tool_called"]
    permissions = [record for record in reports if record.get("event") == "permission_called"]
    sdk_replies = responses(trace, "sdk_to_cli")
    if scenario in ("mcp", "permission_allow", "permission_deny", "permission_replace", "resume"):
        mcp = matching_control(trace, "cli_to_sdk", "mcp_message")
        listings = [request for request in mcp if request["request"].get("message", {}).get("method") == "tools/list"]
        check(len(listings) >= CLIENTS[scenario], "real CLI requested MCP tools/list for each client")
        check(all([tool["name"] for tool in sdk_replies.get((request.get("_phase"), request["request_id"]), {}).get("response", {}).get("mcp_response", {}).get("result", {}).get("tools", [])] == ["probe"] for request in listings), "SDK listed registered harmless probe tool")
        initialized_tools = [record["message"].get("tools", []) for record in trace if record.get("direction") == "cli_to_sdk" and record.get("message", {}).get("type") == "system" and record["message"].get("subtype") == "init"]
        check(any("mcp__matrix__probe" in names for names in initialized_tools), "CLI system/init exposes registered SDK tool")
        calls = [request for request in mcp if request["request"].get("message", {}).get("method") == "tools/call"]
        if scenario == "permission_deny":
            check(not calls and not tool_calls, "denied tool never reaches SDK handler")
        else:
            check(len(calls) == 1 and len(tool_calls) == 1 and tool_calls[0].get("arguments_match") is True, "exactly one real MCP call executes with expected arguments")
            expected = {"value": nonce if scenario == "resume" else "replacement" if scenario == "permission_replace" else "original", "nonce": "resume-proof" if scenario == "resume" else nonce}
            check(calls[0]["request"]["message"].get("params", {}).get("arguments") == expected, "MCP call carries original, replacement, or remembered input as required")
            reply = sdk_replies.get((calls[0].get("_phase"), calls[0]["request_id"]), {}).get("response", {}).get("mcp_response", {})
            check(reply.get("id") == calls[0]["request"]["message"].get("id") and reply.get("result", {}).get("content") == [{"type": "text", "text": "matrix-tool-result"}], "SDK sends correlated successful MCP result")
        if scenario.startswith("permission_"):
            requests = matching_control(trace, "cli_to_sdk", "can_use_tool")
            check(len(requests) == 1 and len(permissions) == 1 and permissions[0].get("input_matches") is True, "real CLI asks host for this unresolved permission")
            decision = sdk_replies.get((requests[0].get("_phase"), requests[0]["request_id"]), {}).get("response", {})
            check(decision.get("behavior") == ("deny" if scenario == "permission_deny" else "allow"), "SDK sends expected correlated permission decision")
            if scenario != "permission_deny":
                expected_value = "replacement" if scenario == "permission_replace" else "original"
                check(decision.get("updatedInput") == {"value": expected_value, "nonce": nonce}, "permission reply supplies intended executable input")
            else:
                denied_result = [block for record in trace if record.get("direction") == "cli_to_sdk" and record.get("message", {}).get("type") == "user" for block in record["message"].get("message", {}).get("content", []) if block.get("type") == "tool_result" and block.get("is_error") is True]
                check(bool(denied_result), "CLI emits failed tool result after host denial")
    if scenario == "interrupt":
        requests = matching_control(trace, "sdk_to_cli", "interrupt")
        check(len(requests) == 1 and cli_responses.get((requests[0].get("_phase"), requests[0].get("request_id")), {}).get("subtype") == "success", "real CLI accepts correlated unmodified interrupt")
        starts = [index for index, record in enumerate(trace) if record.get("direction") == "cli_to_sdk" and record.get("message", {}).get("type") == "stream_event" and record["message"].get("event", {}).get("type") == "message_start"]
        interrupt_indices = [index for index, record in enumerate(trace) if record.get("direction") == "sdk_to_cli" and record.get("message", {}).get("request", {}).get("subtype") == "interrupt"]
        results = [index for index, record in enumerate(trace) if record.get("direction") == "cli_to_sdk" and record.get("message", {}).get("type") == "result"]
        check(bool(starts) and bool(results) and starts[0] < interrupt_indices[0] < results[-1], "interrupt occurs during streamed model turn and reaches terminal result")
        check(not any(record.get("event") == "fault_injected" for record in trace), "success scenario uses no fault injection")
        output = [record for record in trace if record.get("event") == "stream_summary"]
        check(len(output) == 1 and "1\n2\n3\n4\n5" in output[0].get("numeric_prefix", ""), "model started the requested long numeric sequence")
        check(9 <= output[0].get("text_characters", 0) < 300 and not output[0].get("end_marker_seen") and not output[0].get("result_end_marker_seen"), "interrupt stops sequence early before its required terminal marker")
        check(any(record.get("event") == "interrupt_sent_midturn" and record.get("prefix_sequence_observed") is True for record in reports), "public Client interrupted only after observing actual sequence progress")
    if scenario == "interrupt_rejection":
        faults = [record for record in trace if record.get("event") == "fault_injected"]
        check(len(faults) == 1 and faults[0].get("original_subtype") == "interrupt", "explicit second-interrupt invalid-subtype fault is recorded")
        rejected = cli_responses.get((faults[0].get("phase"), faults[0].get("request_id")), {})
        check(rejected.get("subtype") == "error" and rejected.get("error_present") is True, "real CLI rejects intentionally invalid control request")
        check(any(record.get("event") == "interrupt_rejection_observed" and record.get("has_error") is True for record in reports), "public Client.next surfaces correlated CLI rejection")
        check(not any(record.get("direction") == "sdk_to_cli" and record.get("message", {}).get("type") == "user" for record in trace), "rejection scenario sends no model prompt")
    if scenario == "resume":
        check(clients[0].get("resume") is False and clients[1].get("resume") is True, "second distinct Client requests persisted session resume")
        session_ids = [record["message"].get("session_id") for record in trace if record.get("direction") == "cli_to_sdk" and record.get("message", {}).get("type") == "result"]
        check(len(session_ids) == 2 and session_ids[0] == session_ids[1] and session_ids[0] is not None, "CLI preserves session identity across clients")
        check(all(record.get("resume_id_matches") is True for record in sessions), "public sessionId agrees with requested resumed ID")
        check(len(tool_calls) == 1 and tool_calls[0].get("phase") == "resume", "only resumed client calls tool using secret from previous turn")
    results = [record["message"] for record in trace if record.get("direction") == "cli_to_sdk" and record.get("message", {}).get("type") == "result"]
    expected_results = 0 if scenario == "interrupt_rejection" else CLIENTS[scenario]
    check(len(results) == expected_results, "exact expected terminal results")
    exits = [record for record in trace if record.get("event") == "client_exit"]
    sdk_exits = [record for record in reports if record.get("event") == "cli_exit_observed"]
    check(len(exits) == CLIENTS[scenario] and all(record.get("bridge_failed") is False for record in exits), "each real CLI exits with intact bridge evidence")
    check(len(sdk_exits) == CLIENTS[scenario], "public SDK reports each observed CLI exit")
    if scenario == "interrupt":
        result, exit_record = results[0], exits[0]
        normal = result.get("subtype") == "success" and result.get("is_error") is False and exit_record.get("exit_code") == 0
        canceled = result.get("subtype") == "error_during_execution" and result.get("is_error") is True and result.get("terminal_reason") == "aborted_streaming" and exit_record.get("exit_code") == 1
        check(normal or canceled, "interrupt terminal tuple is success/false/exit0 or error_during_execution/true/aborted_streaming/exit1")
        sdk_exit = sdk_exits[0]
        check(sdk_exit.get("exit_code") == exit_record.get("exit_code") and sdk_exit.get("terminal_subtype") == result.get("subtype") and sdk_exit.get("terminal_is_error") is result.get("is_error") and sdk_exit.get("terminal_reason") == (result.get("terminal_reason") or "missing"), "SDK result subtype, error flag, terminal reason and exit agree with real CLI tuple")
    else:
        check(all(result.get("subtype") == "success" and result.get("is_error") is False for result in results), "CLI terminal results are successful")
        check(all(record.get("exit_code") == 0 for record in exits + sdk_exits), "non-interrupt CLI exits remain successful")
    return observed


@dataclass(frozen=True)
class Plan:
    scenarios: tuple[str, ...]
    per_request: Decimal
    total_budget: Decimal
    timeout: float
    clients: int
    turns: int


def make_plan(args):
    try:
        per_request = Decimal(args.max_budget_usd)
        total_budget = Decimal(args.total_budget_usd)
    except InvalidOperation as error:
        raise ValueError("budgets must be decimal numbers") from error
    require(per_request.is_finite() and 0 < per_request <= Decimal("0.05"), "max-budget-usd must be >0 and <=0.05")
    require(total_budget.is_finite() and 0 < total_budget <= Decimal("0.50"), "total-budget-usd must be >0 and <=0.50")
    require(0 < args.timeout_seconds <= 60, "timeout-seconds must be >0 and <=60")
    require(1 <= args.request_limit <= 10, "request-limit must be between 1 and 10")
    scenarios = tuple(args.scenario or DEFAULT_SCENARIOS)
    require(len(set(scenarios)) == len(scenarios), "duplicate scenarios would repeat paid requests")
    clients = sum(CLIENTS[name] for name in scenarios)
    turns = sum(TURNS[name] for name in scenarios)
    require(clients <= args.request_limit, "planned CLI requests exceed request-limit")
    require(turns <= 16, "planned model turns exceed the 16-turn matrix configuration limit")
    require(clients * per_request <= total_budget, "planned CLI budget thresholds exceed total-budget-usd")
    return Plan(scenarios, per_request, total_budget, args.timeout_seconds, clients, turns)


def auth_status(binary):
    code, output = run([binary, "auth", "status", "--json"], timeout=15)
    try:
        status = json.loads(output)
    except (ValueError, TypeError):
        raise ValueError("CLI auth status was not structured JSON; authenticate the selected CLI before model use") from None
    require(isinstance(status, dict), "CLI auth status did not return an object")
    # Whitelist booleans/enums; never return account, organization, or token fields.
    logged_in = status.get("loggedIn") is True
    method = status.get("authMethod")
    safe_method = method if method in ("none", "oauth_token", "claude.ai", "api_key", "apiKey", "oauth", "bedrock", "vertex") else "other"
    return {"logged_in": logged_in and code == 0, "method": safe_method, "exit_code": code}


def compile_runner(root, output):
    code, log = run(["zig", "build-exe", "--dep", "agent", f"-Mroot={root / 'scripts/live_matrix.zig'}", f"-Magent={root / 'src/agent.zig'}", f"-femit-bin={output}"], cwd=root, timeout=120)
    require(code == 0, f"live matrix compilation failed: {log}")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--allow-model-use", action="store_true", help="explicitly authorize the planned bounded live matrix")
    result.add_argument("--prepare", action="store_true", help="compile and print sanitized plan/auth status without model use")
    result.add_argument("--check-auth", action="store_true", help="check login only, without model use")
    result.add_argument("--scenario", action="append", choices=SCENARIOS, help="run selected scenario(s); default runs all isolated scenarios")
    result.add_argument("--max-budget-usd", default="0.05")
    result.add_argument("--total-budget-usd", default="0.40")
    result.add_argument("--request-limit", type=int, default=8)
    result.add_argument("--timeout-seconds", type=float, default=60)
    result.add_argument("--model", default="haiku")
    result.add_argument("--evidence-dir", type=Path, help="new directory for sanitized JSON evidence (required for live execution)")
    return result


def source_hash(paths):
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.name.encode() + b"\0")
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def terminal_costs(trace):
    costs = []
    for record in trace:
        message = record.get("message", {})
        if record.get("direction") != "cli_to_sdk" or message.get("type") != "result":
            continue
        value = message.get("total_cost_usd")
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            continue
        cost = Decimal(str(value))
        if cost.is_finite() and cost >= 0:
            costs.append({"phase": record.get("phase"), "reported_cost_usd": str(cost)})
    return costs


class SessionCleanup:
    """Remove only artifacts named for fresh session UUIDs owned by this run."""
    def __init__(self, session_ids, state_root=None):
        self.state_root = Path(state_root or os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude").expanduser().resolve()
        self.session_ids = set(session_ids)
        for session_id in session_ids:
            require(str(uuid.UUID(session_id)) == session_id, "cleanup requires generated UUIDs")
        require(not self.candidates(), "a generated session ID already has artifacts; refusing to claim ownership")

    def candidates(self):
        found = set()
        for directory in ("projects", "debug", "todos", "tasks", "session-env", "sessions"):
            root = self.state_root / directory
            if not root.exists():
                continue
            # Known CLI layouts: projects/<cwd>/<uuid>.*, debug/<uuid>.*, etc.
            parents = list(root.iterdir()) if directory == "projects" else [root]
            for parent in parents:
                if not parent.is_dir() or parent.is_symlink():
                    continue
                for session_id in self.session_ids:
                    for candidate in parent.glob(session_id + "*"):
                        name = candidate.name
                        if name == session_id or name.startswith(session_id + ".") or name.startswith(session_id + "-"):
                            found.add(candidate)
        return found

    def cleanup(self):
        removed = []
        candidates = self.candidates()
        for candidate in sorted(candidates):
            require(not candidate.is_symlink() and candidate.resolve().is_relative_to(self.state_root), "refusing linked or out-of-state cleanup target")
            if candidate.is_dir():
                require(not any(item.is_symlink() for item in candidate.rglob("*")), "refusing linked session directory cleanup")
                shutil.rmtree(candidate)
            else:
                candidate.unlink()
            removed.append(fingerprint(str(candidate.relative_to(self.state_root))))
        require(not self.candidates(), "owned session artifacts remain after cleanup")
        return {"owned_session_count": len(self.session_ids), "removed_artifact_count": len(removed), "removed_path_fingerprints": removed,
                "owned_session_artifacts_remaining": 0, "scope": "Only newly generated session UUID artifacts; existing CLI global config/caches are retained"}


def input_hashes(root, binary):
    return {
        "cli_binary_sha256": source_hash([Path(binary).resolve()]),
        "sdk_source_sha256": source_hash(list((root / "src").glob("*.zig")) + [root / "build.zig.zon"]),
        "harness_source_sha256": source_hash([root / "scripts" / name for name in ("live_matrix.py", "live_matrix_bridge.py", "live_matrix.zig", "live-compatibility.py", "processes.py")]),
    }


SDK_EVENTS = {"cli_exit_observed", "tool_called", "permission_called", "system_init", "result_received", "interrupt_sent_midturn", "interrupt_rejection_observed", "session_complete", "scenario_complete"}


def read_json_lines(text):
    records = []
    decode_errors = 0
    for line in text.splitlines():
        try:
            value = json.loads(line)
        except (ValueError, TypeError):
            decode_errors += 1
            continue
        if isinstance(value, dict):
            records.append(value)
        else:
            decode_errors += 1
    return records, decode_errors


def collect_scenario(evidence, scenario, trace_path, sdk_trace_path, code, output, command_error):
    # The SDK flushes this mirror before stdout; supervisors may discard stdout.
    sdk_text = sdk_trace_path.read_text() if sdk_trace_path.exists() else output
    raw_reports, sdk_decode_errors = read_json_lines(sdk_text)
    reports = [record for record in raw_reports if record.get("event") in SDK_EVENTS]
    (evidence / f"{scenario}-sdk.json").write_text(json.dumps(reports, indent=2) + "\n")
    trace, wire_decode_errors = read_json_lines(trace_path.read_text() if trace_path.exists() else "")
    costs = terminal_costs(trace)
    terminal_outcomes = []
    exits = {record.get("phase"): record.get("exit_code") for record in trace if record.get("event") == "client_exit"}
    for record in trace:
        message = record.get("message", {})
        if record.get("direction") == "cli_to_sdk" and message.get("type") == "result":
            terminal_outcomes.append({"phase": record.get("phase"), "subtype": message.get("subtype"), "is_error": message.get("is_error"),
                                      "terminal_reason": message.get("terminal_reason"), "cli_exit_code": exits.get(record.get("phase"))})
    result = {"scenario": scenario, "exit_code": code, "passed": False, "terminal_outcomes": terminal_outcomes,
              "reported_cost_usd": str(sum(Decimal(item["reported_cost_usd"]) for item in costs)),
              "terminal_result_costs": costs, "terminal_cost_observed": bool(costs),
              "cost_note": "Only observed terminal result costs; interrupted commands may have unreported usage",
              "sdk_decode_errors": sdk_decode_errors,
              "wire_decode_errors": wire_decode_errors}
    if command_error is not None:
        result["supervisor_error_type"] = type(command_error).__name__
        result["assertions"] = [{"assertion": "scenario command completes without supervisor failure", "passed": False}]
    (evidence / f"{scenario}-assertions.json").write_text(json.dumps(result, indent=2) + "\n")
    return result, trace, reports


def execute(plan, args, binary, root=ROOT, *, fixture=False):
    require(args.evidence_dir is not None, "live execution requires --evidence-dir for reviewable sanitized results")
    evidence = args.evidence_dir.resolve()
    require(not evidence.exists(), "evidence directory already exists; prior results must be preserved")
    evidence.mkdir(parents=True, mode=0o700)
    initial_hashes = input_hashes(root, binary)
    summary = {
        "started_utc": datetime.now(timezone.utc).isoformat(), "source": "synthetic_harness_fixture" if fixture else "live_cli",
        "model": args.model, "scenarios": list(plan.scenarios), "planned_cli_requests": plan.clients,
        "maximum_configured_model_turns": plan.turns, "per_request_budget_threshold_usd": str(plan.per_request),
        "aggregate_budget_threshold_usd": str(plan.clients * plan.per_request),
        "total_budget_ceiling_usd": str(plan.total_budget), "per_scenario_deadline_seconds": plan.timeout,
        "budget_note": "CLI thresholds are not billing guarantees; no automatic retries",
        "interrupt_rejection_note": "Second interrupt subtype is intentionally changed by the bridge; rejection is supplied by the real CLI",
        **initial_hashes,
        "results": [],
    }
    summary_path = evidence / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    session_ids = {scenario: str(uuid.uuid4()) for scenario in plan.scenarios}
    cleanup = SessionCleanup(session_ids.values())
    try:
        code, version = run([binary, "--version"], timeout=15)
        require(code == 0, "CLI version probe failed")
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?: \(Claude Code\))?\s*", version), "unexpected CLI version format")
        summary["cli_version"] = version.strip()
        with tempfile.TemporaryDirectory(prefix="claude-live-matrix-") as temporary:
            workspace = Path(temporary)
            runner = workspace / "matrix"
            compile_runner(root, runner)
            summary["runner_sha256"] = hashlib.sha256(runner.read_bytes()).hexdigest()
            bridge = workspace / "cli"
            bridge.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(root / "scripts/live_matrix_bridge.py")) + ' "$@"\n')
            bridge.chmod(0o700)
            for scenario in plan.scenarios:
                scenario_dir = workspace / scenario
                scenario_dir.mkdir()
                nonce = secrets.token_hex(16)
                trace_path = evidence / f"{scenario}-wire.jsonl"
                sdk_trace_path = evidence / f"{scenario}-sdk.jsonl"
                env = dict(os.environ, LIVE_CLI=str(bridge), LIVE_REAL_CLI=binary,
                           LIVE_NONCE=nonce, LIVE_SCENARIO=scenario, LIVE_MODEL=args.model,
                           LIVE_BUDGET_USD=str(plan.per_request), LIVE_TRACE=str(trace_path), LIVE_SDK_TRACE=str(sdk_trace_path),
                           LIVE_SEED_SESSION_ID=session_ids[scenario], LIVE_TRACE_SOURCE="synthetic_harness_fixture" if fixture else "live_cli",
                           DISABLE_AUTOUPDATER="1", DISABLE_TELEMETRY="1", DISABLE_ERROR_REPORTING="1",
                           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
                print(f"live-compatibility: {scenario}: {CLIENTS[scenario]} CLI client(s), budget threshold {plan.per_request} each", flush=True)
                code, output, command_error = None, "", None
                try:
                    code, output = run([str(runner)], cwd=scenario_dir, env=env, timeout=plan.timeout)
                except BaseException as error:
                    command_error = error
                    partial = getattr(error, "output", None) or getattr(error, "stdout", None)
                    if isinstance(partial, bytes):
                        output = partial.decode("utf-8", "replace")
                    elif isinstance(partial, str):
                        output = partial
                    raise
                finally:
                    result, trace, reports = collect_scenario(evidence, scenario, trace_path, sdk_trace_path, code, output, command_error)
                    summary["results"].append(result)
                try:
                    result["assertions"] = assert_scenario(scenario, trace, reports, nonce)
                    require(code == 0, f"{scenario}: SDK runner exited {code}; inspect sanitized wire/SDK evidence (raw diagnostics withheld)")
                    require(result["wire_decode_errors"] == 0 and result["sdk_decode_errors"] == 0, f"{scenario}: evidence includes malformed or incomplete records")
                    result["passed"] = True
                except ScenarioAssertionError as error:
                    result["assertions"] = error.assertions
                    raise
                finally:
                    (evidence / f"{scenario}-assertions.json").write_text(json.dumps(result, indent=2) + "\n")
                reported = sum(Decimal(item.get("reported_cost_usd", "0")) for item in summary["results"])
                require(reported <= plan.total_budget, "CLI reported cost reached matrix ceiling; no further scenarios executed")
        summary["passed"] = all(result["passed"] for result in summary["results"])
    except BaseException as error:
        summary["passed"] = False
        summary["failure"] = str(error) if isinstance(error, (ValueError, subprocess.TimeoutExpired)) else type(error).__name__
        raise
    finally:
        completion_error = None
        try:
            summary["cleanup"] = cleanup.cleanup()
        except (OSError, ValueError) as error:
            summary["passed"] = False
            summary["cleanup"] = {"failed": True, "error_type": type(error).__name__}
            completion_error = ValueError("owned session artifact cleanup failed")
        try:
            final_hashes = input_hashes(root, binary)
            summary["input_hashes_at_completion"] = final_hashes
            summary["inputs_unchanged"] = final_hashes == initial_hashes
            if not summary["inputs_unchanged"]:
                summary["passed"] = False
                completion_error = ValueError("CLI, SDK, or harness inputs changed during validation")
        except OSError as error:
            summary["passed"] = False
            summary["inputs_unchanged"] = False
            completion_error = ValueError("could not fingerprint validation inputs at completion")
        summary["reported_cost_usd"] = str(sum(Decimal(item.get("reported_cost_usd", "0")) for item in summary["results"]))
        summary["finished_utc"] = datetime.now(timezone.utc).isoformat()
        if completion_error is not None:
            summary["failure"] = str(completion_error)
        summary_path.write_text(json.dumps(summary, indent=2) + "\n")
        if completion_error is not None:
            raise completion_error
    label = "synthetic harness" if fixture else "real CLI"
    print(f"live-compatibility: PASS — {len(plan.scenarios)} {label} semantic scenarios; sanitized evidence at {evidence}")


@contextmanager
def termination_as_interrupt():
    previous = signal.getsignal(signal.SIGTERM)

    def interrupt(_signum, _frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


def main(argv=None):
    with termination_as_interrupt():
        try:
            return run_main(argv)
        except KeyboardInterrupt:
            print("live-compatibility: INTERRUPTED — child cleanup and owned session cleanup attempted", file=sys.stderr)
            return 130


def run_main(argv=None):
    argument_parser = parser()
    args = argument_parser.parse_args(argv)
    if not args.allow_model_use and not args.prepare and not args.check_auth:
        argument_parser.error("model use requires explicit --allow-model-use; normal gates never run this matrix")
    try:
        plan = make_plan(args)
        require(re.fullmatch(r"[A-Za-z0-9_.:/-]{1,100}", args.model), "invalid model name")
    except ValueError as error:
        argument_parser.error(str(error))
    try:
        binary = shutil.which(os.environ.get("CLAUDE_BIN", "claude"))
        require(binary is not None, "CLI is missing")
        auth = auth_status(binary)
        if args.check_auth:
            print(json.dumps(auth, sort_keys=True))
            return 0 if auth["logged_in"] else 1
        if args.prepare:
            with tempfile.TemporaryDirectory(prefix="claude-live-prepare-") as temporary:
                compile_runner(ROOT, Path(temporary) / "matrix")
            print(json.dumps({"auth": auth, "scenarios": plan.scenarios, "planned_cli_requests": plan.clients,
                              "maximum_configured_model_turns": plan.turns, "aggregate_budget_threshold_usd": str(plan.clients * plan.per_request),
                              "compiled": True, "model_requests_executed": 0}, indent=2))
            return 0 if auth["logged_in"] else 1
        require(auth["logged_in"], "selected CLI is not authenticated; run claude auth login before this explicitly opt-in matrix")
        execute(plan, args, binary)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"live-compatibility: FAIL — {error}", file=sys.stderr)
        return 1
    return 0
