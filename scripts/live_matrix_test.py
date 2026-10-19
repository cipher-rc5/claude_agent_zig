"""Offline resource, redaction, semantic-validator, and public-SDK matrix tests."""

import contextlib
import copy
from decimal import Decimal
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import live_matrix as matrix
import live_matrix_fixture as fixture


class LiveMatrixTests(unittest.TestCase):
    def test_fixture_requires_top_level_control_ids_without_nested_duplicates(self):
        good = {"type": "control_request", "request_id": "zig_1", "request": {"subtype": "initialize"}}
        with patch.object(sys, "stdin", io.StringIO(json.dumps(good) + "\n")):
            self.assertEqual(fixture.read_control("initialize")["request_id"], "zig_1")
        for envelope in (
            {"type": "control_request", "request": {"subtype": "initialize", "request_id": "zig_1"}},
            {"type": "control_request", "request_id": "zig_1", "request": {"subtype": "initialize", "request_id": "zig_1"}},
        ):
            with self.subTest(envelope=envelope), patch.object(sys, "stdin", io.StringIO(json.dumps(envelope) + "\n")), self.assertRaises(AssertionError):
                fixture.read_control("initialize")
        sanitized = matrix.sanitize_message({"type": "control_request", "request": {"subtype": "initialize", "request_id": "zig_1"}}, "nonce")
        self.assertIsNone(sanitized["request_id"])
        self.assertFalse(sanitized["envelope_id_present"])
        self.assertTrue(sanitized["nested_id_present"])

    def test_terminal_costs_are_retained_even_from_failed_semantics(self):
        trace = [
            {"direction": "cli_to_sdk", "phase": "main", "message": {"type": "result", "subtype": "success", "total_cost_usd": 0.00034327}},
            {"direction": "cli_to_sdk", "phase": "main", "message": {"type": "result", "subtype": "error_during_execution", "total_cost_usd": 0.001}},
            {"direction": "sdk_to_cli", "message": {"type": "result", "total_cost_usd": 10}},
        ]
        self.assertEqual(matrix.terminal_costs(trace), [{"phase": "main", "reported_cost_usd": "0.00034327"}, {"phase": "main", "reported_cost_usd": "0.001"}])

    def test_default_plan_has_eight_clients_and_bounded_thresholds(self):
        plan = matrix.make_plan(matrix.parser().parse_args([]))
        self.assertEqual(plan.clients, 8)
        self.assertEqual(plan.turns, 12)
        self.assertEqual(plan.clients * plan.per_request, Decimal("0.40"))
        self.assertEqual(plan.scenarios, matrix.DEFAULT_SCENARIOS)

    def test_resource_limits_and_duplicate_paid_scenarios_are_rejected(self):
        invalid = (("--max-budget-usd", "0.051"), ("--max-budget-usd", "NaN"), ("--total-budget-usd", "0.51"), ("--total-budget-usd", "0.39"), ("--request-limit", "7"), ("--request-limit", "11"), ("--timeout-seconds", "61"), ("--timeout-seconds", "nan"), ("--scenario", "mcp", "--scenario", "mcp"))
        for argv in invalid:
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                matrix.make_plan(matrix.parser().parse_args(argv))

    def test_model_use_needs_explicit_opt_in_before_auth_or_compilation(self):
        with patch.object(matrix, "auth_status") as auth, patch.object(matrix, "compile_runner") as compile_runner:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                matrix.main([])
            self.assertEqual(error.exception.code, 2)
            auth.assert_not_called()
            compile_runner.assert_not_called()

    def test_auth_status_never_returns_identity_or_credentials(self):
        raw = {"loggedIn": True, "authMethod": "claude.ai", "email": "secret@example.invalid", "token": "token-secret", "organizationId": "private-org"}
        with patch.object(matrix, "run", return_value=(0, json.dumps(raw))):
            status = matrix.auth_status("fixture")
        self.assertEqual(status, {"logged_in": True, "method": "claude.ai", "exit_code": 0})
        self.assertNotIn("secret", json.dumps(status))

    def test_unauthenticated_preflight_never_executes_model(self):
        with patch.object(matrix.shutil, "which", return_value="fixture"), patch.object(matrix, "auth_status", return_value={"logged_in": False, "method": "none", "exit_code": 1}), patch.object(matrix, "execute") as execute:
            with contextlib.redirect_stderr(io.StringIO()):
                code = matrix.main(["--allow-model-use"])
            self.assertEqual(code, 1)
            execute.assert_not_called()

    def test_sanitizer_omits_paths_identity_tokens_and_arbitrary_model_text(self):
        nonce = "fixture-generated-nonce"
        messages = [
            {"type": "system", "subtype": "init", "session_id": "private-session", "cwd": "/private/user/secret", "email": "private@example.invalid", "apiKeySource": "credential-secret", "tools": ["mcp__matrix__probe", "private-tool"], "mcp_servers": []},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "credential-secret"}, {"type": "tool_use", "id": "tool-1", "name": "mcp__matrix__probe", "input": {"value": "credential-secret", "nonce": nonce, "api_key": "credential-secret"}}]}},
            {"type": "control_response", "response": {"subtype": "error", "request_id": "zig_2", "error": "credential-secret"}},
            {"type": "result", "subtype": "success", "result": "credential-secret", "session_id": "private-session", "total_cost_usd": 0.001},
        ]
        output = json.dumps([matrix.sanitize_message(message, nonce) for message in messages])
        for secret in ("credential-secret", "private-session", "private-tool", "/private/user/secret", "private@example.invalid"):
            self.assertNotIn(secret, output)
        self.assertIn(nonce, output)
        self.assertIn("mcp__matrix__probe", output)

    def test_arbitrary_ids_and_protocol_enum_strings_are_fingerprinted(self):
        private_id = "credential-secret-id"
        request = matrix.sanitize_message({"type": "control_request", "request_id": private_id, "request": {"subtype": "mcp_message", "server_name": "matrix", "message": {"method": "tools/call", "id": private_id, "params": {"name": "probe", "arguments": {}}}}}, "nonce")
        response = matrix.sanitize_message({"type": "control_response", "response": {"request_id": private_id, "subtype": "success", "response": {"mcp_response": {"id": private_id, "jsonrpc": "credential-secret-enum", "result": {"content": [{"type": "credential-secret-enum", "text": "matrix-tool-result"}]}}}}}, "nonce")
        assistant = matrix.sanitize_message({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": private_id, "name": "mcp__matrix__probe", "input": {}}]}}, "nonce")
        user = matrix.sanitize_message({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": private_id}]}}, "nonce")
        result = matrix.sanitize_message({"type": "result", "subtype": "credentialsecretlowercase"}, "nonce")
        encoded = json.dumps([request, response, assistant, user, result])
        self.assertNotIn("credential-secret", encoded)
        self.assertNotIn("credentialsecretlowercase", encoded)
        self.assertEqual(request["request_id"], response["response"]["request_id"])
        self.assertEqual(request["request"]["message"]["id"], response["response"]["response"]["mcp_response"]["id"])
        self.assertEqual(assistant["message"]["content"][0]["id"], user["message"]["content"][0]["tool_use_id"])
        self.assertNotEqual(matrix.correlation_id(1), matrix.correlation_id("1"))

    def test_canceled_interrupt_tuple_requires_abort_reason_correlated_request_and_matching_exit(self):
        with tempfile.TemporaryDirectory(prefix="live-cancel-offline-") as temporary:
            work = Path(temporary)
            cli = work / "fixture-cli"
            cli.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(matrix.ROOT / "scripts/live_matrix_fixture.py")) + ' "$@"\n')
            cli.chmod(0o700)
            args = matrix.parser().parse_args(["--allow-model-use", "--scenario", "interrupt", "--evidence-dir", str(work / "evidence")])
            with patch.dict(os.environ, LIVE_MATRIX_FIXTURE_CANCEL="1"), contextlib.redirect_stdout(io.StringIO()):
                matrix.execute(matrix.make_plan(args), args, str(cli), fixture=True)
            summary = json.loads((args.evidence_dir / "summary.json").read_text())
            self.assertTrue(summary["passed"])
            outcome = summary["results"][0]["terminal_outcomes"][0]
            self.assertEqual(outcome, {"phase": "main", "subtype": "error_during_execution", "is_error": True, "terminal_reason": "aborted_streaming", "cli_exit_code": 1})
            trace = [json.loads(line) for line in (args.evidence_dir / "interrupt-wire.jsonl").read_text().splitlines()]
            reports = json.loads((args.evidence_dir / "interrupt-sdk.json").read_text())
            exit_event = next(record for record in reports if record.get("event") == "cli_exit_observed")
            self.assertEqual(exit_event["exit_code"], 1)
            self.assertEqual(exit_event["terminal_reason"], "aborted_streaming")
            self.assertIs(exit_event["terminal_is_error"], True)
            variants = ("wrong_subtype", "wrong_reason", "missing_reason", "wrong_exit", "missing_interrupt", "incorrect_sdk_exit")
            for variant in variants:
                with self.subTest(variant=variant):
                    modified_trace = copy.deepcopy(trace)
                    modified_reports = copy.deepcopy(reports)
                    terminal = next(record["message"] for record in modified_trace if record.get("message", {}).get("type") == "result")
                    if variant == "wrong_subtype":
                        terminal["subtype"] = "error_max_turns"
                    elif variant == "wrong_reason":
                        terminal["terminal_reason"] = "api_error"
                    elif variant == "missing_reason":
                        terminal.pop("terminal_reason")
                    elif variant == "wrong_exit":
                        next(record for record in modified_trace if record.get("event") == "client_exit")["exit_code"] = 0
                    elif variant == "missing_interrupt":
                        modified_trace = [record for record in modified_trace if not (record.get("direction") == "sdk_to_cli" and record.get("message", {}).get("request", {}).get("subtype") == "interrupt")]
                    else:
                        next(record for record in modified_reports if record.get("event") == "cli_exit_observed")["exit_code"] = 0
                    with self.assertRaises(matrix.ScenarioAssertionError):
                        matrix.assert_scenario("interrupt", modified_trace, modified_reports, "unused nonce")

    def test_supervisor_exceptions_retain_partial_sdk_trace_and_cost_then_reraise(self):
        errors = (subprocess.TimeoutExpired(["fixture"], 1), KeyboardInterrupt(), RuntimeError("fixture output limit"))
        for original_error in errors:
            with self.subTest(error=type(original_error).__name__), tempfile.TemporaryDirectory(prefix="live-supervisor-offline-") as temporary:
                work = Path(temporary)
                cli = work / "fixture-cli"
                cli.write_text("synthetic CLI fingerprint input")
                args = matrix.parser().parse_args(["--allow-model-use", "--scenario", "mcp", "--evidence-dir", str(work / "evidence")])

                def fake_compile(_root, output):
                    output.write_bytes(b"synthetic runner")

                def fake_run(argv, **kwargs):
                    if argv == [str(cli), "--version"]:
                        return 0, "99.0.0 (Claude Code)\n"
                    environment = kwargs["env"]
                    Path(environment["LIVE_TRACE"]).write_text(json.dumps({"direction": "cli_to_sdk", "phase": "main", "message": {"type": "result", "total_cost_usd": 0.002}}) + "\n" + '{"incomplete":')
                    Path(environment["LIVE_SDK_TRACE"]).write_text(json.dumps({"event": "system_init", "phase": "main", "initialization": "accepted"}) + "\n")
                    raise original_error

                with patch.object(matrix, "compile_runner", side_effect=fake_compile), patch.object(matrix, "run", side_effect=fake_run), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(type(original_error)) as caught:
                    matrix.execute(matrix.make_plan(args), args, str(cli), fixture=True)
                self.assertIs(caught.exception, original_error)
                summary = json.loads((args.evidence_dir / "summary.json").read_text())
                result = json.loads((args.evidence_dir / "mcp-assertions.json").read_text())
                reports = json.loads((args.evidence_dir / "mcp-sdk.json").read_text())
                self.assertFalse(summary["passed"])
                self.assertEqual(summary["reported_cost_usd"], "0.002")
                self.assertEqual(len(summary["results"]), 1)
                self.assertEqual(result["supervisor_error_type"], type(original_error).__name__)
                self.assertEqual(result["reported_cost_usd"], "0.002")
                self.assertTrue(result["terminal_cost_observed"])
                self.assertEqual(result["wire_decode_errors"], 1)
                self.assertEqual(reports, [{"event": "system_init", "phase": "main", "initialization": "accepted"}])

    def test_partial_exception_output_is_used_when_sdk_mirror_is_unavailable(self):
        with tempfile.TemporaryDirectory(prefix="live-partial-offline-") as temporary:
            evidence = Path(temporary)
            report = {"event": "system_init", "phase": "main", "initialization": "accepted"}
            result, trace, reports = matrix.collect_scenario(evidence, "mcp", evidence / "missing-wire", evidence / "missing-mirror", None,
                                                           json.dumps(report) + "\nraw-secret-must-not-persist\n", subprocess.TimeoutExpired(["fixture"], 1))
            self.assertEqual(reports, [report])
            self.assertFalse(result["terminal_cost_observed"])
            self.assertEqual(result["reported_cost_usd"], "0")
            self.assertNotIn("raw-secret", (evidence / "mcp-sdk.json").read_text())
            self.assertEqual(trace, [])

    def test_sanitizer_accepts_only_exact_probe_name_and_boolean_rpc_error_flag(self):
        secret_name = "mcp__matrix__private-secret-tool"
        self.assertNotEqual(matrix.safe_tool_name(secret_name), secret_name)
        self.assertEqual(matrix.safe_tool_name("mcp__matrix__probe"), "mcp__matrix__probe")
        for value in ("private-secret-error", False):
            reply = matrix.sanitize_message({"type": "control_response", "response": {"subtype": "success", "request_id": "r", "response": {"mcp_response": {"jsonrpc": "2.0", "id": 1, "result": {"isError": value}}}}}, "nonce")
            observed = reply["response"]["response"]["mcp_response"]["result"]["isError"]
            if value is False:
                self.assertIs(observed, False)
            else:
                self.assertNotIn("private-secret", json.dumps(reply))
                self.assertTrue(observed.startswith("sha256:"))

    def test_failed_semantic_assertion_keeps_terminal_result_cost_in_summary(self):
        with tempfile.TemporaryDirectory(prefix="live-cost-offline-") as temporary:
            work = Path(temporary)
            cli = work / "fixture-cli"
            cli.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(matrix.ROOT / "scripts/live_matrix_fixture.py")) + ' "$@"\n')
            cli.chmod(0o700)
            args = matrix.parser().parse_args(["--allow-model-use", "--scenario", "mcp", "--evidence-dir", str(work / "evidence")])
            failure = matrix.ScenarioAssertionError("deliberate offline assertion failure", [{"assertion": "fixture failure", "passed": False}])
            with patch.object(matrix, "assert_scenario", side_effect=failure), contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "deliberate offline"):
                matrix.execute(matrix.make_plan(args), args, str(cli), fixture=True)
            summary = json.loads((args.evidence_dir / "summary.json").read_text())
            result = json.loads((args.evidence_dir / "mcp-assertions.json").read_text())
            self.assertFalse(summary["passed"])
            self.assertEqual(summary["reported_cost_usd"], "0.001")
            self.assertEqual(summary["results"][0]["reported_cost_usd"], "0.001")
            self.assertEqual(result["reported_cost_usd"], "0.001")
            self.assertEqual(result["terminal_result_costs"], [{"phase": "main", "reported_cost_usd": "0.001"}])

    def test_changed_completion_fingerprint_invalidates_semantic_success(self):
        with tempfile.TemporaryDirectory(prefix="live-hash-offline-") as temporary:
            work = Path(temporary)
            cli = work / "fixture-cli"
            cli.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(matrix.ROOT / "scripts/live_matrix_fixture.py")) + ' "$@"\n')
            cli.chmod(0o700)
            args = matrix.parser().parse_args(["--allow-model-use", "--scenario", "mcp", "--evidence-dir", str(work / "evidence")])
            initial = {"cli_binary_sha256": "a" * 64, "sdk_source_sha256": "b" * 64, "harness_source_sha256": "c" * 64}
            changed = dict(initial, cli_binary_sha256="d" * 64)
            with patch.object(matrix, "input_hashes", side_effect=[initial, changed]), contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "inputs changed"):
                matrix.execute(matrix.make_plan(args), args, str(cli), fixture=True)
            summary = json.loads((args.evidence_dir / "summary.json").read_text())
            self.assertFalse(summary["passed"])
            self.assertFalse(summary["inputs_unchanged"])
            self.assertTrue(summary["results"][0]["passed"], "semantic scenario should pass before hash invalidation")
            self.assertEqual(summary["input_hashes_at_completion"], changed)

    def test_sigterm_preserves_summary_and_cleans_owned_session_files(self):
        with tempfile.TemporaryDirectory(prefix="live-sigterm-offline-") as temporary:
            work = Path(temporary)
            cli = work / "fixture-cli"
            cli.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(matrix.ROOT / "scripts/live_matrix_fixture.py")) + ' "$@"\n')
            cli.chmod(0o700)
            ready = work / "ready"
            evidence = work / "evidence"
            state = work / "state"
            env = dict(os.environ, CLAUDE_BIN=str(cli), CLAUDE_CONFIG_DIR=str(state), LIVE_MATRIX_FIXTURE_HOLD="1", LIVE_MATRIX_FIXTURE_READY=str(ready))
            env["PYTHONPATH"] = str(matrix.ROOT / "scripts")
            wrapper = "import sys; from unittest.mock import patch; import live_matrix as m; original=m.execute; patched=lambda *a,**kw: original(*a,**kw,fixture=True); ctx=patch.object(m,'execute',patched); ctx.start(); sys.exit(m.main())"
            driver = subprocess.Popen([sys.executable, "-c", wrapper, "--allow-model-use", "--scenario", "mcp", "--evidence-dir", str(evidence)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
                while not ready.exists() and driver.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists(), "synthetic fixture did not establish owned-session readiness")
                driver.terminate()
                self.assertEqual(driver.wait(timeout=10), 130)
                summary = json.loads((evidence / "summary.json").read_text())
                self.assertFalse(summary["passed"])
                self.assertEqual(summary["failure"], "KeyboardInterrupt")
                self.assertEqual(summary["cleanup"]["removed_artifact_count"], 1)
                self.assertEqual(summary["cleanup"]["owned_session_artifacts_remaining"], 0)
                self.assertTrue(summary["inputs_unchanged"])
                self.assertEqual(list(state.rglob("*.jsonl")), [])
            finally:
                if driver.poll() is None:
                    driver.kill()
                    driver.wait(timeout=5)

    def test_cleanup_removes_only_this_run_generated_session_artifacts(self):
        import uuid
        with tempfile.TemporaryDirectory(prefix="live-cleanup-") as temporary:
            state = Path(temporary)
            project = state / "projects" / "disposable-cwd"
            project.mkdir(parents=True)
            existing = project / "existing-user-session.jsonl"
            existing.write_text("private previous session")
            session_id = str(uuid.uuid4())
            cleanup = matrix.SessionCleanup([session_id], state)
            owned = project / (session_id + ".jsonl")
            owned.write_text("new fixture session")
            debug = state / "debug"
            debug.mkdir()
            (debug / (session_id + ".txt")).write_text("new debug")
            result = cleanup.cleanup()
            self.assertEqual(result["removed_artifact_count"], 2)
            self.assertTrue(existing.exists())
            self.assertFalse(owned.exists())
            self.assertEqual(result["owned_session_artifacts_remaining"], 0)

    def test_cleanup_refuses_preexisting_uuid_ownership_and_links(self):
        import uuid
        with tempfile.TemporaryDirectory(prefix="live-cleanup-") as temporary:
            state = Path(temporary)
            debug = state / "debug"
            debug.mkdir()
            session_id = str(uuid.uuid4())
            existing = debug / (session_id + ".txt")
            existing.write_text("existing")
            with self.assertRaisesRegex(ValueError, "already has artifacts"):
                matrix.SessionCleanup([session_id], state)
            existing.unlink()
            cleanup = matrix.SessionCleanup([session_id], state)
            external = state / "existing-private-file"
            external.write_text("private")
            existing.symlink_to(external)
            with self.assertRaisesRegex(ValueError, "refusing linked"):
                cleanup.cleanup()
            self.assertTrue(external.exists())

    def test_all_semantic_scenarios_against_explicitly_synthetic_cli(self):
        # This tests the harness itself. It cannot certify live CLI behavior.
        with tempfile.TemporaryDirectory(prefix="live-matrix-offline-") as temporary:
            work = Path(temporary)
            cli = work / "fixture-cli"
            cli.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(matrix.ROOT / "scripts/live_matrix_fixture.py")) + ' "$@"\n')
            cli.chmod(0o700)
            args = matrix.parser().parse_args(["--allow-model-use", "--evidence-dir", str(work / "evidence")])
            plan = matrix.make_plan(args)
            with contextlib.redirect_stdout(io.StringIO()):
                matrix.execute(plan, args, str(cli), fixture=True)
            summary = json.loads((args.evidence_dir / "summary.json").read_text())
            self.assertTrue(summary["passed"])
            self.assertEqual(summary["source"], "synthetic_harness_fixture")
            self.assertTrue(summary["inputs_unchanged"])
            self.assertEqual(summary["input_hashes_at_completion"]["cli_binary_sha256"], summary["cli_binary_sha256"])
            self.assertEqual(len(summary["results"]), 7)
            for result in summary["results"]:
                self.assertTrue(result["passed"], result)
                self.assertTrue(all(assertion["passed"] for assertion in result["assertions"]))
            for path in args.evidence_dir.iterdir():
                content = path.read_text()
                self.assertNotIn("credential-do-not-record", content)
                self.assertNotIn("/private/do-not-record", content)
            # A final assistant text is insufficient without a real correlated call.
            trace = [json.loads(line) for line in (args.evidence_dir / "mcp-wire.jsonl").read_text().splitlines()]
            reports = json.loads((args.evidence_dir / "mcp-sdk.json").read_text())
            nonce = next(record["message"]["request"]["message"]["params"]["arguments"]["nonce"] for record in trace if record.get("message", {}).get("request", {}).get("message", {}).get("method") == "tools/call")
            without_call = [record for record in trace if record.get("message", {}).get("request", {}).get("message", {}).get("method") != "tools/call"]
            with self.assertRaisesRegex(ValueError, "exactly one real MCP call"):
                matrix.assert_scenario("mcp", without_call, reports, nonce)
            interrupted_trace = [json.loads(line) for line in (args.evidence_dir / "interrupt-wire.jsonl").read_text().splitlines()]
            interrupted_reports = json.loads((args.evidence_dir / "interrupt-sdk.json").read_text())
            for record in interrupted_trace:
                if record.get("event") == "stream_summary":
                    record["text_characters"] = 1000
            with self.assertRaisesRegex(ValueError, "stops sequence early"):
                matrix.assert_scenario("interrupt", interrupted_trace, interrupted_reports, "unused nonce")


if __name__ == "__main__":
    unittest.main()
