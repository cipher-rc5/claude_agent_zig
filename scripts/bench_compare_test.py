"""Offline regression tests for paired benchmark collection and interpretation."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import random
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import bench_compare as bench


def record(workload="normal", lines=3):
    return {
        "benchmark_schema": 1, "zig_version": "0.17.0", "optimize": "fast", "target": "aarch64-macos-none",
        "workload": workload, "run": 1, "events": lines + 1 + (workload == "recovery"),
        "controls": lines if workload == "control" else 0, "delta_bytes": 303,
        "events_per_second": 1_000_000, "ns_per_event": 1000,
        "latency_p50_ns": 900, "latency_p95_ns": 1100, "latency_p99_ns": 1300, "latency_max_ns": 2000,
        "allocated_bytes_per_event": 5600, "allocations_per_event": 6,
        "peak_sdk_bytes": 90_000, "retained_sdk_bytes": 83_000, "after_close_sdk_bytes": 0,
    }


class ScheduleTests(unittest.TestCase):
    def test_seeded_balanced_pairs_include_every_workload_and_warmup(self):
        jobs = bench.schedule(bench.WORKLOADS, 20, 3, 42)
        self.assertEqual(jobs, bench.schedule(bench.WORKLOADS, 20, 3, 42))
        self.assertNotEqual(jobs, bench.schedule(bench.WORKLOADS, 20, 3, 43))
        self.assertEqual(len(jobs), 230)
        for first, second in zip(jobs[::2], jobs[1::2], strict=True):
            self.assertEqual((first["phase"], first["pair"], first["workload"]),
                             (second["phase"], second["pair"], second["workload"]))
            self.assertEqual({first["implementation"], second["implementation"]}, {"before", "after"})
            self.assertEqual((first["order"], second["order"]), (0, 1))
        for phase, count in (("warmup", 3), ("measure", 20)):
            for workload in bench.WORKLOADS:
                firsts = [row for row in jobs if row["phase"] == phase and row["workload"] == workload and row["order"] == 0]
                self.assertEqual({row["pair"] for row in firsts}, set(range(1, count + 1)))
                before = sum(row["implementation"] == "before" for row in firsts)
                self.assertLessEqual(abs(before - (count - before)), 1)


class RecordTests(unittest.TestCase):
    def test_rejects_incomplete_inconsistent_and_nonfinite_measurements(self):
        cases = ({"events": 3}, {"controls": 1}, {"run": 2}, {"benchmark_schema": True},
                 {"target": ""}, {"events_per_second": float("nan")}, {"allocations_per_event": True},
                 {"ns_per_event": 10}, {"latency_p95_ns": 800}, {"after_close_sdk_bytes": 1},
                 {"retained_sdk_bytes": 100_000}, {"latency_p50_ns": 900.5}, {"peak_sdk_bytes": 10**1000})
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                bench.decode_record(json.dumps(record() | changes), "normal", 3)
        for text in ("", "{}\n{}", "[]", "not json"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                bench.decode_record(text, "normal", 3)

    def test_control_and_recovery_counts_follow_the_selected_workload(self):
        for workload in bench.WORKLOADS:
            self.assertEqual(record(workload), bench.decode_record(json.dumps(record(workload)), workload, 3))


class SummaryTests(unittest.TestCase):
    def samples(self):
        result = []
        for pair, before, after in ((1, 100, 200), (2, 1000, 1000)):
            for implementation, speed in (("before", before), ("after", after)):
                result.append(record() | {"phase": "measure", "pair": pair, "implementation": implementation,
                                          "events_per_second": speed})
        # Warmup outliers must not affect any measured distribution.
        result.append(record() | {"phase": "warmup", "pair": 1, "implementation": "after", "events_per_second": 1e20})
        random.Random(5).shuffle(result)
        return result

    def test_uses_paired_changes_instead_of_ratio_of_unpaired_medians(self):
        summary = bench.summarize(self.samples(), ["normal"], 17, 1000)
        normal = summary["workloads"]["normal"]
        self.assertEqual(normal["pairs"], 2)
        self.assertEqual(normal["paired_changes"]["events_per_second"]["percent"]["median"], 50)
        self.assertEqual(normal["paired_changes"]["events_per_second"]["bootstrap_95_percentile_interval"], [0, 100])
        self.assertEqual(normal["metrics"]["after"]["events_per_second"]["max"], 1000)
        self.assertTrue(normal["small_sample"])
        self.assertEqual(summary, bench.summarize(self.samples(), ["normal"], 17, 1000))

    def test_rejects_incomplete_and_duplicate_pairs(self):
        samples = [row for row in self.samples() if row["phase"] == "measure"]
        with self.assertRaises(ValueError):
            bench.summarize(samples[:-1], ["normal"], 17, 100)
        with self.assertRaises(ValueError):
            bench.summarize(samples + [samples[0]], ["normal"], 17, 100)
        change = bench.paired_change([0, 1], [1, 1], random.Random(0), 100)
        self.assertIsNone(change["percent"])


class CollectorTests(unittest.TestCase):
    def setUp(self):
        (bench.ROOT / "_dev").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="bench-compare-test-", dir=bench.ROOT / "_dev")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.source = self.work / "not-compiled.zig"
        self.source.write_text("intentionally not Zig; collection must never compile supplied sources\n")
        self.binary = self.work / "fixture"
        self.binary.write_text(f"#!{sys.executable}\nimport json, sys\nr = {record()!r}\n"
                               "r['workload'] = sys.argv[2]\nr['events'] = int(sys.argv[1]) + 1 + (sys.argv[2] == 'recovery')\n"
                               "r['controls'] = int(sys.argv[1]) if sys.argv[2] == 'control' else 0\nprint(json.dumps(r))\n")
        self.binary.chmod(0o755)
        self.output = self.work / "results"

    def arguments(self):
        return ["--before", str(self.binary), "--after", str(self.binary),
                "--before-source", str(self.source), "--after-source", str(self.source),
                "--benchmark-source", str(self.source), "--output", str(self.output),
                "--seed", "42", "--pairs", "2", "--warmup", "1", "--lines", "3",
                "--workloads", "normal", "recovery", "--bootstrap-samples", "100"]

    def collect(self, extra=()):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return bench.main(self.arguments() + list(extra))

    def test_supervised_collection_keeps_raw_warmups_fingerprints_and_paired_summary(self):
        self.assertEqual(self.collect(), 0)
        environment = json.loads((self.output / "environment.json").read_text())
        self.assertEqual(environment["status"], "complete")
        self.assertEqual(environment["binaries"]["before"]["sha256"], bench.digest(self.binary))
        self.assertEqual(environment["sources"]["after"]["sha256"], bench.digest(self.source))
        raw = [json.loads(line) for line in (self.output / "raw.jsonl").read_text().splitlines()]
        self.assertEqual(len(raw), 12)
        self.assertEqual(sum(row["phase"] == "warmup" for row in raw), 4)
        self.assertTrue(all("host_load_before" in row and "process_seconds" in row for row in raw))
        summary = json.loads((self.output / "summary.json").read_text())
        self.assertEqual(summary["workloads"]["recovery"]["pairs"], 2)
        original = (self.output / "raw.jsonl").read_bytes()
        self.assertEqual(self.collect(), 1)
        self.assertEqual((self.output / "raw.jsonl").read_bytes(), original)

    def test_nonzero_exit_and_timeout_preserve_failure_without_a_summary(self):
        self.binary.write_text(f"#!{sys.executable}\nraise SystemExit(7)\n")
        self.assertEqual(self.collect(), 1)
        self.assertIn("exited 7", json.loads((self.output / "environment.json").read_text())["error"])
        self.assertFalse((self.output / "summary.json").exists())
        self.output = self.work / "timeout"
        self.binary.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(10)\n")
        started = time.monotonic()
        self.assertEqual(self.collect(["--timeout-seconds", ".1"]), 1)
        self.assertLess(time.monotonic() - started, 8)
        self.assertIn("TimeoutExpired", json.loads((self.output / "environment.json").read_text())["error"])

    def test_mixed_compilers_and_mutated_sources_never_produce_a_completed_report(self):
        first = json.dumps(record())
        second = json.dumps(record() | {"zig_version": "0.18.0"})
        with patch.object(bench, "run", side_effect=[(0, first), (0, second)]):
            self.assertEqual(self.collect(["--pairs", "1", "--warmup", "0", "--workloads", "normal"]), 1)
        self.assertIn("differs", json.loads((self.output / "environment.json").read_text())["error"])
        self.output = self.work / "source-mutated"

        def mutate(*_args, **_kwargs):
            self.source.write_text("changed during measurement\n")
            return 0, first

        with patch.object(bench, "run", side_effect=mutate):
            self.assertEqual(self.collect(["--pairs", "1", "--warmup", "0", "--workloads", "normal"]), 1)
        self.assertIn("source fingerprints changed", json.loads((self.output / "environment.json").read_text())["error"])
        self.assertFalse((self.output / "summary.json").exists())

    def test_interrupted_measurement_records_failure_and_does_not_report_success(self):
        with patch.object(bench, "run", side_effect=KeyboardInterrupt):
            self.assertEqual(self.collect(), 130)
        environment = json.loads((self.output / "environment.json").read_text())
        self.assertEqual(environment["status"], "failed")
        self.assertIn("KeyboardInterrupt", environment["error"])
        self.assertFalse((self.output / "summary.json").exists())


if __name__ == "__main__":
    unittest.main()
