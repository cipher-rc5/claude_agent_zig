#!/usr/bin/env python3
"""Record fresh macOS runtime tests, bounded stress, fuzzing, and optional CLI checks."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

from processes import run

ROOT = Path(__file__).resolve().parent.parent
MODES = ("Debug", "ReleaseSafe", "ReleaseFast")
TEST_ROOTS = ("src/agent.zig", "tests/all.zig", "examples/demo.zig")
PRIVATE_FILTERS = ("signal cannot enter",)
PUBLIC_FILTERS = (
    "concurrent waits", "force recovery", "status snapshots", "termination escalates",
    "kill from another thread", "transport_contract_test",
)
PUBLIC_REQUIRED = (
    "concurrent waits reap once", "force recovery bypasses", "status snapshots remain coherent",
    "termination escalates an ignored TERM", "transport contract: a failed send",
    "transport contract: forceKill bypasses", "transport contract: one-byte buffers",
)
FUZZ_TARGETS = (
    ("line", "readLine neither panics", "client.test.readLine neither panics nor stalls on arbitrary bytes"),
    ("dispatch", "serveControlRequest answers or stays silent",
     "client.test.serveControlRequest answers or stays silent on arbitrary JSON, never panics"),
)


class ValidationFailure(RuntimeError):
    pass


def iteration_count(text: str) -> int:
    match = re.fullmatch(r"(\d+)([KMG]?)", text.upper())
    if match is None:
        raise argparse.ArgumentTypeError("use a nonnegative integer, optionally followed by K, M, or G")
    value = int(match[1]) * {"": 1, "K": 1_000, "M": 1_000_000, "G": 1_000_000_000}[match[2]]
    if value > 10_000_000:
        raise argparse.ArgumentTypeError("iteration limit must not exceed 10M")
    return value


def positive_seconds(text: str) -> float:
    value = float(text)
    if not 0 < value <= 3_600:
        raise argparse.ArgumentTypeError("timeout must be greater than zero and at most 3600 seconds")
    return value


def require_platform(requested: str, actual: str | None = None) -> dict:
    actual = sys.platform if actual is None else actual
    if requested != "macos" or actual != "darwin":
        raise ValidationFailure(f"native macOS execution is required; requested {requested}, actual {actual}")
    uname = platform.uname()
    return {"validated_platform": "macos", "python_platform": actual,
            "kernel": uname.system, "kernel_release": uname.release, "kernel_version": uname.version,
            "architecture": uname.machine, "macos_version": platform.mac_ver()[0],
            "cpu_count": os.cpu_count()}


def source_snapshot(root: Path) -> dict:
    files = set()
    for directory in ("src", "tests", "examples", "bench", "scripts", ".githooks"):
        files.update(path for path in (root / directory).rglob("*")
                     if path.is_file() and "__pycache__" not in path.parts and
                     (path.suffix in (".zig", ".py", ".sh") or path.name.startswith("pre-")))
    files.update(root / name for name in ("build.zig", "build.zig.zon", "justfile"))
    hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted(files) if path.is_file()}
    combined = hashlib.sha256()
    for path, digest in hashes.items():
        combined.update(path.encode() + b"\0" + digest.encode() + b"\n")
    return {"sha256": combined.hexdigest(), "files": hashes}


def require_ignored_output(root: Path, output: Path) -> None:
    try:
        relative = output.relative_to(root)
    except ValueError as error:
        raise ValidationFailure("--output must be inside this repository's ignored _dev directory") from error
    if not relative.parts or relative.parts[0] != "_dev":
        raise ValidationFailure("--output must be inside this repository's ignored _dev directory")
    if "_dev/" not in (root / ".gitignore").read_text().splitlines():
        raise ValidationFailure("the repository no longer ignores _dev/")
    if output.exists() and any(output.iterdir()):
        raise ValidationFailure("--output must name a new or empty directory")


def test_accounting(output: str, required=()) -> dict:
    summaries = re.findall(r"^All (\d+) tests passed\.$", output, re.MULTILINE)
    if len(summaries) != 1 or int(summaries[0]) == 0:
        raise ValidationFailure("no unambiguous nonempty successful test execution was reported")
    total = int(summaries[0])
    cases = re.findall(r"^(\d+)/(\d+) (.+?)\.\.\.OK$", output, re.MULTILINE)
    if len(cases) != total or [int(case[0]) for case in cases] != list(range(1, total + 1)) or \
            any(int(case[1]) != total for case in cases):
        raise ValidationFailure("test execution counts do not match the successful summary")
    names = [case[2] for case in cases]
    for expected in required:
        if not any(expected in name for name in names):
            raise ValidationFailure(f"required test was not executed: {expected}")
    return {"executed": total, "passed": total, "skipped": 0, "names": names}


def fuzz_accounting(output: str, expected: str, requested: int) -> dict:
    names = re.findall(r'^Fuzz test: "([^"]+)"', output, re.MULTILINE)
    runs = re.findall(r"^Runs: (\d+) -> (\d+)$", output, re.MULTILINE)
    if names != [expected] or len(runs) != 1:
        raise ValidationFailure("fuzz output does not identify exactly the requested harness")
    before, after = map(int, runs[0])
    if after - before < requested:
        raise ValidationFailure("reported new fuzz executions do not reach the requested limit")
    return {"harness": expected, "requested_iteration_limit": requested,
            "reported_runs_start": before, "reported_runs_end": after,
            "new_executions": after - before,
            "note": "Zig's finite fuzz iteration limit can overshoot; actual counts are preserved."}


class Validator:
    def __init__(self, root: Path, output: Path, work: Path, options, supervisor=None):
        self.root, self.output, self.work = root, output, work
        self.options, self.supervisor = options, supervisor or run
        self.lock = threading.Lock()
        self.env = dict(os.environ, ZIG_LOCAL_CACHE_DIR=str(work / "cache"),
                        ZIG_GLOBAL_CACHE_DIR=os.environ.get("ZIG_GLOBAL_CACHE_DIR", str(work / "global-cache")))
        self.report = {"schema_version": 1, "started_utc": datetime.now(timezone.utc).isoformat(),
                       "status": "running", "native_runtime_verified": False,
                       "complete_runtime_acceptance": False, "compile_only": options.compile_only,
                       "scope": {"modes": list(MODES), "test_roots": list(TEST_ROOTS),
                                 "stress_repetitions_per_group": options.stress_repetitions,
                                 "fuzz_iteration_limit_per_harness": options.fuzz_iterations,
                                 "stress_workers": options.workers, "seed": options.seed},
                       "execution_policy": {"matrix": "fresh direct test-binary processes",
                                            "stress": "fresh process for every repetition",
                                            "fuzz": "finite generated runs with reported execution deltas",
                                            "supervisor": "scripts/processes.py"},
                       "environment_overrides": {key: self.sanitize(self.env[key]) for key in
                                                 ("ZIG_LOCAL_CACHE_DIR", "ZIG_GLOBAL_CACHE_DIR")},
                       "cli_compatibility": {"strict_requested": options.strict_canary,
                                             "status": "not_run", "model_usage": "none"},
                       "path_placeholders": {"$REPOSITORY": "repository root", "$OUTPUT": "requested evidence directory",
                                             "$WORK": "temporary compiler cache and binaries", "$HOME": "user home"},
                       "steps": []}

    def sanitize(self, text: str) -> str:
        replacements = ((str(self.root), "$REPOSITORY"), (str(self.output), "$OUTPUT"),
                        (str(self.work), "$WORK"), (str(Path.home()), "$HOME"))
        for old, new in sorted(replacements, key=lambda pair: len(pair[0]), reverse=True):
            text = text.replace(old, new)
        text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
        text = re.sub(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}\b", "[REDACTED_KEY]", text)
        return "".join(char for char in text if char in "\n\t" or ord(char) >= 32)

    def save(self):
        target = self.output / "report.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.report, indent=2, sort_keys=True) + "\n")
        temporary.replace(target)

    def step(self, name: str, argv: list[str], timeout: float, accounting=None):
        if re.fullmatch(r"stress-(?:private|public)-\d+", name) is None:
            print(f"runtime-validation: {name}", flush=True)
        record = {"name": name, "command": [self.sanitize(arg) for arg in argv], "cwd": "$REPOSITORY",
                  "timeout_seconds": timeout, "status": "running", "log": name + ".log"}
        with self.lock:
            self.report["steps"].append(record)
            self.save()
        started = time.monotonic()
        try:
            code, output = self.supervisor(argv, timeout=timeout, cwd=self.root, env=self.env)
            output = self.sanitize(output)
            (self.output / record["log"]).write_text(output)
            with self.lock:
                record.update(exit_code=code, elapsed_seconds=round(time.monotonic() - started, 3),
                              output_sha256=hashlib.sha256(output.encode()).hexdigest())
            if code != 0:
                raise ValidationFailure(f"{name} exited with status {code}; see {record['log']}")
            if accounting is not None:
                details = accounting(output)
                with self.lock:
                    record["accounting"] = details
            with self.lock:
                record["status"] = "passed"
            return output
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            with self.lock:
                record.update(status="failed", elapsed_seconds=round(time.monotonic() - started, 3),
                              error=self.sanitize(str(error)))
            if not (self.output / record["log"]).exists():
                (self.output / record["log"]).write_text(record["error"] + "\n")
            raise ValidationFailure(f"{name}: {self.sanitize(str(error))}") from error
        finally:
            with self.lock:
                self.save()

    def compile_tests(self, root: str, mode: str, path: Path, filters=()):
        argv = [self.options.zig, "test", "-O" + mode]
        if root != "src/agent.zig":
            argv += ["--dep", "agent"]
        argv += ["-Mroot=" + root]
        if root != "src/agent.zig":
            argv += ["-O" + mode, "-Magent=src/agent.zig"]
        argv += ["--test-no-exec", "-femit-bin=" + str(path)]
        for selected in filters:
            argv += ["--test-filter", selected]
        return argv

    def matrix(self):
        for mode in MODES:
            for index, root in enumerate(TEST_ROOTS):
                label = "matrix-" + mode.lower() + "-" + str(index)
                binary = self.work / label
                self.step(label + "-compile", self.compile_tests(root, mode, binary), self.options.compile_timeout)
                if not self.options.compile_only:
                    required = ("transport.test.",) if root == "src/agent.zig" else ()
                    self.step(label + "-execute", [str(binary), f"--seed={self.options.seed}"],
                              self.options.run_timeout, lambda output, required=required: test_accounting(output, required))

    def stress(self):
        groups = {"private": ("src/agent.zig", PRIVATE_FILTERS, PRIVATE_FILTERS),
                  "public": ("tests/all.zig", PUBLIC_FILTERS, PUBLIC_REQUIRED)}
        binaries = {}
        for group, (root, filters, _) in groups.items():
            binary = self.work / ("stress-" + group)
            self.step("stress-" + group + "-compile", self.compile_tests(root, "Debug", binary, filters),
                      self.options.compile_timeout)
            binaries[group] = binary
        if self.options.compile_only or self.options.stress_repetitions == 0:
            return

        def execute(group, repetition):
            self.step(f"stress-{group}-{repetition:04d}",
                      [str(binaries[group]), f"--seed={(self.options.seed + repetition) & 0xffffffff}"],
                      self.options.run_timeout,
                      lambda output: test_accounting(output, groups[group][2]))

        executor = ThreadPoolExecutor(max_workers=self.options.workers)
        futures = [executor.submit(execute, group, repetition)
                   for repetition in range(self.options.stress_repetitions) for group in groups]
        try:
            for index, future in enumerate(as_completed(futures), 1):
                future.result()
                if index % 20 == 0:
                    print(f"runtime-validation: {index}/{len(futures)} stress processes passed", flush=True)
        finally:
            executor.shutdown(wait=True, cancel_futures=True)

    def fuzz(self):
        if self.options.compile_only or self.options.fuzz_iterations == 0:
            return
        for name, selected, expected in FUZZ_TARGETS:
            argv = [self.options.zig, "build", "test", f"--fuzz={self.options.fuzz_iterations}",
                    "-Dtest-filter=" + selected, f"--seed=0x{self.options.seed:x}", "--summary", "all"]
            self.step("fuzz-" + name, argv, self.options.fuzz_timeout,
                      lambda output, expected=expected: fuzz_accounting(output, expected, self.options.fuzz_iterations))

    def validate(self):
        self.report["host"] = require_platform(self.options.platform)
        self.report["source_before"] = source_snapshot(self.root)
        version = self.step("zig-version", [self.options.zig, "version"], 15).strip()
        manifest = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"',
                             (self.root / "build.zig.zon").read_text())
        if manifest is None or version != manifest[1]:
            raise ValidationFailure("installed Zig does not exactly match build.zig.zon's tested version")
        self.report["toolchain"] = {"version": version, "expected_version": manifest[1]}
        self.step("zig-environment", [self.options.zig, "env"], 15)
        self.matrix()
        self.stress()
        self.fuzz()
        if self.options.strict_canary and not self.options.compile_only:
            self.report["cli_compatibility"]["status"] = "running"
            output = self.step("strict-canary", [sys.executable, "-B", "scripts/canary.py", "--strict"], 120)
            if "canary: PASS" not in output or "canary: SKIP" in output:
                raise ValidationFailure("strict canary did not prove compatibility")
            self.report["cli_compatibility"]["status"] = "passed"
            version = re.search(r"canary: PASS\s*[—-]\s*([^;\n]+)", output)
            self.report["cli_compatibility"]["version_response"] = version[1] if version else "see strict-canary.log"
        elif self.options.compile_only:
            self.report["cli_compatibility"]["status"] = "not_run_compile_only"
        self.report["source_after"] = source_snapshot(self.root)
        if self.report["source_before"] != self.report["source_after"]:
            raise ValidationFailure("validation inputs changed during execution; results cannot verify one source tree")
        self.report["native_runtime_verified"] = not self.options.compile_only
        self.report["complete_runtime_acceptance"] = (not self.options.compile_only and
            self.options.stress_repetitions >= 100 and self.options.fuzz_iterations >= 100_000)
        self.report["status"] = "compiled" if self.options.compile_only else "passed"


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("macos",), default="macos")
    parser.add_argument("--output", type=Path, required=True, help="new or empty evidence directory under _dev/")
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--compile-only", action="store_true", help="record compilation without claiming runtime validation")
    parser.add_argument("--stress-repetitions", type=int, default=100)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--fuzz-iterations", type=iteration_count, default=100_000)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x6e3b3)
    parser.add_argument("--strict-canary", action="store_true", help="require installed CLI compatibility; never uses a model")
    parser.add_argument("--compile-timeout", type=positive_seconds, default=300)
    parser.add_argument("--run-timeout", type=positive_seconds, default=30)
    parser.add_argument("--fuzz-timeout", type=positive_seconds, default=120)
    options = parser.parse_args(argv)
    if not 0 <= options.stress_repetitions <= 10_000:
        parser.error("--stress-repetitions must be between 0 and 10000")
    if not 1 <= options.workers <= 16:
        parser.error("--workers must be between 1 and 16")
    if not 0 <= options.seed <= 0xffffffff:
        parser.error("--seed must fit an unsigned 32-bit integer")
    return options


def validate_main(argv=None):
    options = arguments(argv)
    output = options.output.resolve()
    try:
        require_ignored_output(ROOT, output)
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="claude-runtime-validation-") as temporary:
            validator = Validator(ROOT, output, Path(temporary), options)
            started = time.monotonic()
            try:
                validator.validate()
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                stopped = isinstance(error, KeyboardInterrupt)
                validator.report.update(status="interrupted" if stopped else "failed",
                                        error="validation interrupted" if stopped else validator.sanitize(str(error)))
                if validator.report["cli_compatibility"]["status"] == "running":
                    validator.report["cli_compatibility"]["status"] = "failed"
            finally:
                if "source_before" in validator.report:
                    validator.report["source_after"] = source_snapshot(ROOT)
                validator.report.update(finished_utc=datetime.now(timezone.utc).isoformat(),
                                        elapsed_seconds=round(time.monotonic() - started, 3))
                validator.report["steps"].sort(key=lambda step: step["name"])
                validator.save()
            if validator.report["status"] == "interrupted":
                print("runtime-validation: interrupted; partial evidence retained", file=sys.stderr)
                return 130
            if validator.report["status"] == "failed":
                raise ValidationFailure(validator.report["error"])
            print(f"runtime-validation: {validator.report['status']} — {output / 'report.json'}")
            if validator.report["cli_compatibility"]["status"] != "passed":
                print("runtime-validation: CLI strict compatibility was not checked")
            return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"runtime-validation: FAIL — {error}", file=sys.stderr)
        return 1


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


def main(argv=None):
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        return validate_main(argv)
    except KeyboardInterrupt:
        print("runtime-validation: interrupted", file=sys.stderr)
        return 130
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    sys.exit(main())
