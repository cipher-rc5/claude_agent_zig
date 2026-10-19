"""Fail-closed accounting tests for runtime evidence; no Zig or model execution."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import runtime_validation as validation


def passed(names):
    return "".join(f"{index}/{len(names)} {name}...OK\n" for index, name in enumerate(names, 1)) + \
           f"All {len(names)} tests passed.\n"


class FakeCommands:
    def __init__(self):
        self.calls = []
        self.failure = None
        self.mutate = None

    def __call__(self, argv, **kwargs):
        self.calls.append((list(argv), kwargs))
        if self.failure:
            result = self.failure(argv)
            if result is not None:
                return result
        if self.mutate:
            self.mutate(argv)
        if argv[1:] == ["version"]:
            return 0, "0.17.0\n"
        if argv[1:] == ["env"]:
            return 0, '.{ .version = "0.17.0" }\n'
        if "--test-no-exec" in argv:
            return 0, ""
        if "--fuzz=100000" in argv or any(arg.startswith("--fuzz=") for arg in argv):
            requested = int(next(arg.split("=", 1)[1] for arg in argv if arg.startswith("--fuzz=")))
            selected = next(arg.split("=", 1)[1] for arg in argv if arg.startswith("-Dtest-filter="))
            expected = next(full for _, filtered, full in validation.FUZZ_TARGETS if filtered == selected)
            return 0, f'Fuzz test: "{expected}" (fixture)\nRuns: 11 -> {11 + requested}\n'
        if argv[-1] == "--strict":
            return 0, "canary: PASS — 2.1.261 (fixture); parser probes verified\n"
        binary = Path(argv[0]).name
        if binary == "stress-private":
            return 0, passed(["agent.test_0", "client.test.signal cannot enter the kernel-reap to status-publication interval"])
        if binary == "stress-public":
            return 0, passed(["all.test_0"] + list(validation.PUBLIC_REQUIRED))
        if binary.startswith("matrix-"):
            return 0, passed(["agent.test_0", "transport.test.fixture"])
        raise AssertionError(f"unexpected fake command: {argv}")


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="runtime-evidence-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = (Path(self.temporary.name) / "repo").resolve()
        self.root.mkdir()
        (self.root / ".gitignore").write_text("_dev/\n")
        (self.root / "build.zig.zon").write_text('.{ .minimum_zig_version = "0.17.0" }\n')
        (self.root / "src").mkdir()
        (self.root / "src/client.zig").write_text("// fixture\n")
        self.output = self.root / "_dev/evidence"
        self.output.mkdir(parents=True)
        self.work = Path(self.temporary.name) / "work"
        self.work.mkdir()
        self.fake = FakeCommands()

    def validator(self, *args):
        options = validation.arguments(["--output", str(self.output), "--stress-repetitions", "2",
                                        "--fuzz-iterations", "10", *args])
        return validation.Validator(self.root, self.output, self.work, options, supervisor=self.fake)

    def validate(self, validator):
        with patch.object(validation, "require_platform", return_value={"validated_platform": "macos"}), redirect_stdout(io.StringIO()):
            validator.validate()
        return validator.report

    def test_matrix_executes_explicit_binaries_in_every_mode(self):
        validator = self.validator()
        report = self.validate(validator)
        compilations = [step for step in report["steps"] if step["name"].startswith("matrix-") and step["name"].endswith("-compile")]
        executions = [step for step in report["steps"] if step["name"].startswith("matrix-") and step["name"].endswith("-execute")]
        self.assertEqual(len(compilations), 9)
        self.assertEqual(len(executions), 9)
        self.assertTrue(all("--test-no-exec" in step["command"] for step in compilations))
        self.assertTrue(all(step["command"][0].startswith("$WORK/matrix-") for step in executions))
        self.assertTrue(all(step["accounting"]["executed"] == 2 for step in executions))
        self.assertTrue(report["native_runtime_verified"])
        self.assertFalse(report["complete_runtime_acceptance"])
        self.assertEqual(report["cli_compatibility"]["status"], "not_run")
        self.assertEqual(report["source_before"], report["source_after"])

    def test_compile_only_cannot_claim_runtime_or_cli_validation(self):
        report = self.validate(self.validator("--compile-only", "--strict-canary"))
        self.assertEqual(report["status"], "compiled")
        self.assertFalse(report["native_runtime_verified"])
        self.assertFalse(report["complete_runtime_acceptance"])
        self.assertEqual(report["cli_compatibility"]["status"], "not_run_compile_only")
        self.assertFalse(any(step["name"].endswith("-execute") or step["name"].startswith("fuzz-") for step in report["steps"]))
        self.assertEqual(len([call for call, _ in self.fake.calls if "--test-no-exec" in call]), 11)

    def test_complete_acceptance_requires_100_fresh_processes_per_group_and_fuzz_limits(self):
        report = self.validate(self.validator("--stress-repetitions", "100", "--fuzz-iterations", "100K"))
        for group in ("private", "public"):
            executions = [step for step in report["steps"] if step["name"].startswith("stress-" + group + "-") and "accounting" in step]
            self.assertEqual(len(executions), 100)
            self.assertEqual(len({step["command"][1] for step in executions}), 100)
        self.assertTrue(report["complete_runtime_acceptance"])
        self.assertEqual(len([step for step in report["steps"] if step["name"].startswith("fuzz-")]), 2)

    def test_a_cached_build_summary_cannot_count_as_test_execution(self):
        self.fake.failure = lambda argv: (0, "Build Summary: 7/7 steps succeeded\ntest cached\n") if Path(argv[0]).name.startswith("matrix-") else None
        with self.assertRaisesRegex(validation.ValidationFailure, "test execution"):
            self.validate(self.validator())

    def test_successful_exit_without_required_stress_test_is_rejected(self):
        self.fake.failure = lambda argv: (0, passed(["agent.test_0"])) if Path(argv[0]).name == "stress-private" else None
        with self.assertRaisesRegex(validation.ValidationFailure, "required test"):
            self.validate(self.validator())

    def test_nonzero_command_is_recorded_and_stops_validation(self):
        self.fake.failure = lambda argv: (9, "fixture failed\n") if "--test-no-exec" in argv else None
        validator = self.validator()
        with self.assertRaisesRegex(validation.ValidationFailure, "status 9"):
            self.validate(validator)
        self.assertFalse(validator.report["native_runtime_verified"])
        self.assertEqual(validator.report["steps"][-1]["status"], "failed")
        self.assertEqual(len(self.fake.calls), 3)

    def test_timeout_fails_instead_of_promoting_partial_evidence(self):
        def timeout(argv):
            if "--test-no-exec" in argv:
                raise subprocess.TimeoutExpired(argv, 3)
        self.fake.failure = timeout
        validator = self.validator()
        with self.assertRaises(validation.ValidationFailure):
            self.validate(validator)
        self.assertEqual(validator.report["steps"][-1]["status"], "failed")
        self.assertFalse(validator.report["complete_runtime_acceptance"])

    def test_source_mutation_invalidates_a_successful_execution(self):
        def mutate(argv):
            if Path(argv[0]).name.startswith("matrix-"):
                (self.root / "src/client.zig").write_text("// changed\n")
        self.fake.mutate = mutate
        with self.assertRaisesRegex(validation.ValidationFailure, "inputs changed"):
            self.validate(self.validator())

    def test_wrong_toolchain_fails_before_compilation(self):
        self.fake.failure = lambda argv: (0, "0.18.0\n") if argv[1:] == ["version"] else None
        with self.assertRaisesRegex(validation.ValidationFailure, "exactly match"):
            self.validate(self.validator())
        self.assertEqual(len(self.fake.calls), 1)

    def test_strict_canary_must_prove_success_and_cannot_skip(self):
        report = self.validate(self.validator("--strict-canary"))
        self.assertEqual(report["cli_compatibility"]["status"], "passed")
        self.assertIn("2.1.261", report["cli_compatibility"]["version_response"])
        self.fake.failure = lambda argv: (0, "canary: SKIP — missing\n") if argv[-1] == "--strict" else None
        with self.assertRaisesRegex(validation.ValidationFailure, "did not prove"):
            self.validate(self.validator("--strict-canary"))

    def test_sanitized_reports_do_not_record_home_paths_or_api_tokens(self):
        validator = self.validator()
        value = f"{self.root}/src/client.zig {self.work}/binary {Path.home()}/credential sk-ant-1234567890abcdefghij"
        safe = validator.sanitize(value)
        self.assertIn("$REPOSITORY/src/client.zig", safe)
        self.assertIn("$WORK/binary", safe)
        self.assertIn("$HOME/credential", safe)
        self.assertNotIn("1234567890abcdefghij", safe)

    def test_main_writes_failed_report_on_platform_mismatch_without_running_commands(self):
        with patch.object(validation, "ROOT", self.root), patch.object(validation.sys, "platform", "linux"), \
             patch.object(validation, "run", self.fake), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = validation.main(["--output", str(self.output)])
        self.assertEqual(code, 1)
        report = json.loads((self.output / "report.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["native_runtime_verified"])
        self.assertEqual(self.fake.calls, [])

    def test_interrupted_campaign_retains_partial_report_without_claiming_success(self):
        with patch.object(validation, "ROOT", self.root), \
             patch.object(validation.Validator, "validate", side_effect=KeyboardInterrupt), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            code = validation.main(["--output", str(self.output)])
        report = json.loads((self.output / "report.json").read_text())
        self.assertEqual(code, 130)
        self.assertEqual(report["status"], "interrupted")
        self.assertFalse(report["native_runtime_verified"])
        self.assertFalse(report["complete_runtime_acceptance"])


class AccountingTests(unittest.TestCase):
    def test_platform_requires_real_darwin(self):
        for actual in ("linux", "win32", "freebsd"):
            with self.subTest(actual=actual), self.assertRaises(validation.ValidationFailure):
                validation.require_platform("macos", actual)
        self.assertEqual(validation.require_platform("macos", "darwin")["validated_platform"], "macos")

    def test_test_counts_and_required_names_are_checked(self):
        self.assertEqual(validation.test_accounting(passed(["one", "two"]), ("two",))["executed"], 2)
        for output in ("All 0 tests passed.\n", "All 2 tests passed.\n", passed(["one"]).replace("1/1", "1/2"),
                       passed(["one"]) + passed(["one"])):
            with self.subTest(output=output), self.assertRaises(validation.ValidationFailure):
                validation.test_accounting(output)

    def test_fuzz_requires_matching_harness_and_new_executions(self):
        expected = "fixture harness"
        output = 'Fuzz test: "fixture harness" (fixture)\nRuns: 30 -> 130\n'
        self.assertEqual(validation.fuzz_accounting(output, expected, 100)["new_executions"], 100)
        for text in ("test cached", output.replace("harness", "other"), output.replace("130", "129"), output + output):
            with self.subTest(text=text), self.assertRaises(validation.ValidationFailure):
                validation.fuzz_accounting(text, expected, 100)

    def test_output_must_be_empty_and_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".gitignore").write_text("_dev/\n")
            validation.require_ignored_output(root, root / "_dev/new")
            for output in (root / "src/evidence", root.parent / "outside-evidence"):
                with self.assertRaises(validation.ValidationFailure):
                    validation.require_ignored_output(root, output)
            output = root / "_dev/old"
            output.mkdir(parents=True)
            (output / "report.json").write_text("{}")
            with self.assertRaises(validation.ValidationFailure):
                validation.require_ignored_output(root, output)


if __name__ == "__main__":
    unittest.main()
