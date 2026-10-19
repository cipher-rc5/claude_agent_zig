#!/usr/bin/env python3
"""Compare explicit benchmark executables in balanced, randomized pairs."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import signal
import statistics
import subprocess
import sys
import time

from processes import run

ROOT = Path(__file__).resolve().parent.parent
WORKLOADS = ("normal", "escaped", "large", "control", "recovery")
METRICS = (
    "events_per_second", "ns_per_event", "latency_p50_ns", "latency_p95_ns",
    "latency_p99_ns", "latency_max_ns", "allocated_bytes_per_event",
    "allocations_per_event", "peak_sdk_bytes", "retained_sdk_bytes", "after_close_sdk_bytes",
)
BUILD_FIELDS = ("benchmark_schema", "zig_version", "optimize", "target")


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def fingerprint(path: Path):
    if path.is_file():
        return {"path": str(path), "sha256": digest(path), "bytes": path.stat().st_size}
    if not path.is_dir():
        raise ValueError(f"missing source: {path}")
    files = {str(file.relative_to(path)): digest(file) for file in sorted(path.rglob("*.zig")) if file.is_file()}
    if not files:
        raise ValueError(f"no Zig sources in {path}")
    return {"path": str(path), "files": files}


def host():
    return {
        "utc": datetime.now(timezone.utc).isoformat(), "hostname": platform.node(),
        "platform": platform.platform(), "machine": platform.machine(),
        "processor": platform.processor(), "python": platform.python_version(),
        "logical_cpus": os.cpu_count(), "load_average": list(os.getloadavg()),
    }


def schedule(workloads, pairs: int, warmup: int, seed: int):
    rng = random.Random(seed)
    result = []
    for phase, count in (("warmup", warmup), ("measure", pairs)):
        orders = {}
        for workload in workloads:
            first = ["before", "after"] * (count // 2)
            if count % 2:
                first.append(rng.choice(("before", "after")))
            rng.shuffle(first)
            orders[workload] = first
        for pair in range(count):
            shuffled = list(workloads)
            rng.shuffle(shuffled)
            for workload in shuffled:
                first = orders[workload][pair]
                for order, implementation in enumerate((first, "after" if first == "before" else "before")):
                    result.append({"phase": phase, "pair": pair + 1, "workload": workload,
                                   "order": order, "implementation": implementation})
    return result


def decode_record(output: str, workload: str, lines: int):
    rows = [line for line in output.splitlines() if line.strip()]
    if len(rows) != 1:
        raise ValueError("expected exactly one benchmark JSON record")
    record = json.loads(rows[0])
    if not isinstance(record, dict):
        raise ValueError("benchmark record must be an object")
    expected = {"benchmark_schema": 1, "workload": workload, "run": 1,
                "events": lines + 1 + (workload == "recovery"),
                "controls": lines if workload == "control" else 0}
    for field, value in expected.items():
        if type(record.get(field)) is not type(value) or record[field] != value:
            raise ValueError(f"unexpected {field}: {record.get(field)!r}, expected {value!r}")
    for field in ("zig_version", "optimize", "target"):
        if not isinstance(record.get(field), str) or not record[field]:
            raise ValueError(f"missing benchmark build metadata: {field}")
    for field in (*METRICS, "delta_bytes"):
        value = record.get(field)
        valid = ((type(value) is int and 0 <= value < 2**64) or
                 (type(value) is float and math.isfinite(value) and value >= 0))
        if not valid:
            raise ValueError(f"invalid benchmark metric: {field}")
    for field in ("latency_p50_ns", "latency_p95_ns", "latency_p99_ns", "latency_max_ns",
                  "peak_sdk_bytes", "retained_sdk_bytes", "after_close_sdk_bytes", "delta_bytes"):
        if type(record[field]) is not int:
            raise ValueError(f"benchmark count must be an integer: {field}")
    if record["events_per_second"] <= 0 or record["ns_per_event"] <= 0:
        raise ValueError("throughput and mean latency must be positive")
    if not math.isclose(record["events_per_second"] * record["ns_per_event"], 1e9, rel_tol=.01):
        raise ValueError("throughput and mean latency disagree")
    latencies = [record[field] for field in ("latency_p50_ns", "latency_p95_ns", "latency_p99_ns", "latency_max_ns")]
    if latencies != sorted(latencies):
        raise ValueError("latency percentiles are out of order")
    if record["retained_sdk_bytes"] > record["peak_sdk_bytes"]:
        raise ValueError("retained memory exceeds peak memory")
    if record["after_close_sdk_bytes"] != 0:
        raise ValueError("benchmark leaked counted SDK memory")
    return record


def distribution(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def paired_change(before, after, rng, bootstrap_samples: int):
    if any(value == 0 for value in before):
        return {"percent": None, "reason": "zero baseline; no finite percentage change"}
    changes = [100 * (a / b - 1) for b, a in zip(before, after, strict=True)]
    bootstrap = sorted(statistics.median(rng.choices(changes, k=len(changes))) for _ in range(bootstrap_samples))
    return {"percent": distribution(changes),
            "bootstrap_95_percentile_interval": [bootstrap[int(.025 * (bootstrap_samples - 1))],
                                                 bootstrap[math.ceil(.975 * (bootstrap_samples - 1))]]}


def summarize(records, workloads, seed: int, bootstrap_samples: int):
    summary = {}
    for workload in workloads:
        samples = [row for row in records if row["phase"] == "measure" and row["workload"] == workload]
        paired = {}
        for row in samples:
            slot = paired.setdefault(row["pair"], {})
            if row["implementation"] in slot:
                raise ValueError("duplicate paired measurement")
            slot[row["implementation"]] = row
        if not paired or any(set(pair) != {"before", "after"} for pair in paired.values()):
            raise ValueError("incomplete paired measurements")
        ordered = [paired[key] for key in sorted(paired)]
        metrics = {implementation: {
            metric: distribution([pair[implementation][metric] for pair in ordered]) for metric in METRICS
        } for implementation in ("before", "after")}
        workload_seed = seed ^ int.from_bytes(hashlib.sha256(workload.encode()).digest()[:8], "big")
        rng = random.Random(workload_seed)
        changes = {metric: paired_change([pair["before"][metric] for pair in ordered],
                                         [pair["after"][metric] for pair in ordered], rng, bootstrap_samples)
                   for metric in ("events_per_second", "allocated_bytes_per_event")}
        summary[workload] = {"pairs": len(ordered), "metrics": metrics, "paired_changes": changes,
                             "small_sample": len(ordered) < 10}
    return {"workloads": summary, "interpretation": (
        "Descriptive paired percentage changes with seeded percentile-bootstrap intervals; "
        "no correction for multiple workloads or shared-host interference. Warmups are excluded. "
        "Intervals do not prove equivalence, causality, or a quiet host. No automatic performance gate.")}


def write_json(path: Path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--before", type=Path, required=True, help="explicit executable; never compiled by this tool")
    result.add_argument("--after", type=Path, required=True)
    result.add_argument("--before-source", type=Path, required=True, help="Zig source file or tree used for the before build")
    result.add_argument("--after-source", type=Path, required=True)
    result.add_argument("--benchmark-source", type=Path, default=ROOT / "bench/next_bench.zig")
    result.add_argument("--output", type=Path, default=ROOT / "_dev/reviews/008/performance", help="new directory under ignored _dev/")
    result.add_argument("--seed", type=int, required=True)
    result.add_argument("--pairs", type=int, default=20)
    result.add_argument("--warmup", type=int, default=3, help="warmup pairs per workload, excluded from summaries")
    result.add_argument("--lines", type=int, default=20_000)
    result.add_argument("--workloads", nargs="+", choices=WORKLOADS, default=list(WORKLOADS))
    result.add_argument("--timeout-seconds", type=float, default=120)
    result.add_argument("--total-timeout-seconds", type=float, default=1800)
    result.add_argument("--bootstrap-samples", type=int, default=10_000)
    result.add_argument("--quiet", action="store_true", help="omit per-sample progress")
    return result


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


def main(argv=None):
    command = parser()
    args = command.parse_args(argv)
    if not 0 <= args.seed < 2**64 or not 1 <= args.pairs <= 1000 or not 0 <= args.warmup <= 100:
        command.error("seed must be u64, pairs 1..1000, and warmup 0..100")
    if not 1 <= args.lines <= 1_000_000 or not 100 <= args.bootstrap_samples <= 100_000:
        command.error("lines must be 1..1000000 and bootstrap-samples 100..100000")
    if any(not math.isfinite(value) or not 0 < value <= 3600 for value in (args.timeout_seconds, args.total_timeout_seconds)):
        command.error("timeouts must be finite, positive, and at most 3600 seconds")
    if len(set(args.workloads)) != len(args.workloads):
        command.error("workloads must be unique")
    binaries = {name: getattr(args, name).resolve() for name in ("before", "after")}
    if any(not file.is_file() or not os.access(file, os.X_OK) for file in binaries.values()):
        command.error("before and after must be executable files")
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / "_dev"):
        command.error("output must remain under ignored _dev/")
    manifest = None
    previous_term = signal.signal(signal.SIGTERM, interrupted)
    try:
        sources = {"before": fingerprint(args.before_source.resolve()), "after": fingerprint(args.after_source.resolve()),
                   "benchmark": fingerprint(args.benchmark_source.resolve()),
                   "comparison_tool": fingerprint(Path(__file__).resolve()),
                   "process_supervisor": fingerprint(ROOT / "scripts/processes.py")}
        binary_fingerprints = {name: fingerprint(file) for name, file in binaries.items()}
        output.mkdir(parents=True, exist_ok=False)
        work = output / "work"
        work.mkdir()
        jobs = schedule(args.workloads, args.pairs, args.warmup, args.seed)
        write_json(output / "schedule.json", jobs)
        manifest = {"schema": 1, "status": "running", "host_start": host(), "seed": args.seed,
                    "configuration": {key: getattr(args, key) for key in (
                        "pairs", "warmup", "lines", "workloads", "timeout_seconds", "total_timeout_seconds", "bootstrap_samples")},
                    "sources": sources, "binaries": binary_fingerprints,
                    "source_provenance": "Provided source fingerprints are recorded, not proof of compilation provenance.",
                    "measurement_scope": "Benchmark timing excludes process startup, transcript creation, ready event, and wait/reap. Each returned event includes next/accessors/deinit. Process wall times include the complete supervised invocation.",
                    "sampling": "Balanced randomized before/after order within each workload; workload order randomized each round. Each sample is a fresh process with one benchmark repetition."}
        write_json(output / "environment.json", manifest)
        measured = []
        build = None
        deadline = time.monotonic() + args.total_timeout_seconds
        with (output / "raw.jsonl").open("w") as raw:
            for sample, job in enumerate(jobs, 1):
                implementation = job["implementation"]
                if fingerprint(binaries[implementation]) != binary_fingerprints[implementation]:
                    raise ValueError(f"{implementation} executable changed during measurement")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("total measurement deadline expired")
                argv = [str(binaries[implementation]), str(args.lines), job["workload"], "1"]
                started = time.monotonic()
                load = list(os.getloadavg())
                code, text = run(argv, cwd=work, timeout=min(remaining, args.timeout_seconds))
                if code:
                    (output / "failed-output.txt").write_text(text)
                    raise RuntimeError(f"sample {sample} {implementation}/{job['workload']} exited {code}")
                try:
                    record = decode_record(text, job["workload"], args.lines)
                except (ValueError, TypeError) as error:
                    (output / "failed-output.txt").write_text(text)
                    raise ValueError(f"sample {sample}: {error}") from error
                current_build = {field: record[field] for field in BUILD_FIELDS}
                if current_build["optimize"] != "fast":
                    raise ValueError("benchmark executable must report optimize=fast (ReleaseFast)")
                if build is None:
                    build = current_build
                elif build != current_build:
                    raise ValueError("benchmark compiler, optimization mode, schema, or target differs between samples")
                row = {**record, **job, "sample": sample, "command": argv, "host_load_before": load,
                       "process_seconds": time.monotonic() - started}
                measured.append(row)
                raw.write(json.dumps(row, allow_nan=False) + "\n")
                raw.flush()
                if not args.quiet:
                    print(f"bench-compare: {sample}/{len(jobs)} {job['phase']} {implementation}/{job['workload']}", flush=True)
        if any(fingerprint(Path(value["path"])) != value for value in sources.values()):
            raise ValueError("source fingerprints changed during measurement")
        if any(fingerprint(file) != binary_fingerprints[name] for name, file in binaries.items()):
            raise ValueError("benchmark executable changed during measurement")
        write_json(output / "summary.json", summarize(measured, args.workloads, args.seed, args.bootstrap_samples))
        manifest.update(status="complete", build=build, host_end=host(), samples=len(measured))
        write_json(output / "environment.json", manifest)
    except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        if manifest is not None:
            manifest.update(status="failed", error=f"{type(error).__name__}: {error}", host_end=host())
            write_json(output / "environment.json", manifest)
        print(f"bench-compare: FAIL — {error}", file=sys.stderr)
        return 130 if isinstance(error, KeyboardInterrupt) else 1
    finally:
        signal.signal(signal.SIGTERM, previous_term)
    print(f"bench-compare: complete — {output}; inspect variance and host load before drawing timing conclusions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
