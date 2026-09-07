#!/usr/bin/env python3
"""Compare equivalent count, Arrow-table, and streaming workloads.

Cold time includes startup/imports/query/exit. Warm time is a second
query in an initialized process after one untimed query. Peak RSS always
comes from the cold process. See docs/BENCHMARKS.md for the contracts.
"""
import argparse
import json
import os
import shutil
import statistics
import platform
import subprocess
import sys
import tempfile

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(REPO, "zig-out", "bin")
CLI = os.path.join(BIN, "scanio.exe" if sys.platform == "win32" else "scanio")

WHERE_COL, WHERE_VAL = "cab_type", "yellow"
WHERE = f"{WHERE_COL} = {WHERE_VAL}"

# ── running one engine ────────────────────────────────────────────────
# Drivers report JSON; the CLI reports a bare integer. Every repetition
# is checked against the generated fixture, including the streaming sink.

RUNNER = r"""
import json, subprocess, sys, time
if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    class ProcessMemoryCounters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in (
                "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage",
            )
        ]

    memory_info = ctypes.WinDLL("psapi", use_last_error=True).GetProcessMemoryInfo
    memory_info.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessMemoryCounters), wintypes.DWORD]
    memory_info.restype = wintypes.BOOL
else:
    import resource

cmd = json.loads(sys.argv[1])
t0 = time.monotonic()
with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                      encoding="utf-8", errors="replace") as p:
    out, err = p.communicate()
    el = time.monotonic() - t0
    if sys.platform == "win32":
        # Popen retains its process handle after communicate(), even for
        # short-lived children. Read the OS peak before releasing it.
        counters = ProcessMemoryCounters()
        counters.cb = ctypes.sizeof(counters)
        if not memory_info(int(p._handle), ctypes.byref(counters), counters.cb):
            raise ctypes.WinError(ctypes.get_last_error())
        rss = counters.PeakWorkingSetSize / (1024.0 ** 2)
    else:
        divisor = 1024.0 ** 2 if sys.platform == "darwin" else 1024.0
        rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / divisor
    print(json.dumps({"secs": el, "rss_mb": rss, "out": out, "err": err[-400:], "rc": p.returncode}))
"""


def run_once(cmd, extra_env=None):
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(RUNNER)
        runner = f.name
    try:
        env = dict(os.environ)
        if extra_env:
            env.update(extra_env)
        p = subprocess.run([sys.executable, runner, json.dumps(cmd)],
                           capture_output=True, encoding="utf-8", errors="replace", env=env)
        if p.returncode != 0:
            raise RuntimeError(f"benchmark runner exited {p.returncode}: {p.stderr.strip()}")
        return json.loads(p.stdout)
    finally:
        os.unlink(runner)


FIELDS = "trip_id cab_type passengers distance fare tip total vendor".split()
WORKLOADS = {
    "count": "Filtered count — scalar result, no matching table collected",
    "arrow": "Materialized Arrow — all eight string columns retained",
    "stream": "Streaming import — consume every matching field and checksum lengths",
}
ENGINES = {
    "count": [("libscanio-cli", "libscanio CLI (zig)"),
              ("libscanio-python", "libscanio Python"),
              ("libscanio-node", "libscanio Node"),
              ("pyarrow", "PyArrow (Python)"), ("polars", "Polars (Python)")],
    "arrow": [("libscanio-python", "libscanio Python"),
              ("pyarrow", "PyArrow (Python)"), ("polars", "Polars (Python)"),
              ("apache-arrow", "Apache Arrow JS + CSV/JSON parser")],
    "stream": [("libscanio-python", "libscanio Python"),
               ("native-python", "Python csv/json"),
               ("libscanio-node", "libscanio Node"),
               ("native-node", "Node readline (fixture CSV/JSON)")],
}


def fixture_row(i):
    # Strings in BOTH formats: no engine silently pays a different type
    # inference/conversion cost. Numeric analytics need a separate fixture.
    return dict(zip(FIELDS, map(str, (
        600000000 + i, ("yellow", "green", "blue")[i % 3], i % 6 + 1,
        (i % 997) / 10.0, (i % 523) + 2.5, (i % 37) / 4.0,
        (i % 600) + 5.25, f"V{i % 4}",
    ))))


def write_fixture(tmp, rows, fmt):
    path = os.path.join(tmp, f"bench.{fmt}")
    with open(path, "w", encoding="utf-8", newline="") as f:
        if fmt == "csv":
            f.write(",".join(FIELDS) + "\n")
        for i in range(rows):
            row = fixture_row(i)
            f.write((",".join(row.values()) if fmt == "csv" else json.dumps(row)) + "\n")
    return path


def expected_result(rows, workload):
    expected = {"rows": (rows + 2) // 3}
    if workload == "arrow":
        expected["columns"] = len(FIELDS)
    elif workload == "stream":
        expected["checksum"] = sum(sum(map(len, fixture_row(i).values()))
                                   for i in range(0, rows, 3))
    return expected


def engine_command(engine, workload, path, fmt, timing):
    if engine == "libscanio-cli":
        return [CLI, path, "--where", WHERE, "--count"]
    runtime = "node" if engine.endswith("-node") or engine == "apache-arrow" else "python"
    impl = engine.split("-")[0]
    if engine == "apache-arrow":
        impl = engine
    script = os.path.join(REPO, "bench", "engine.js" if runtime == "node" else "engine.py")
    prefix = ["node", "--expose-gc"] if runtime == "node" else [sys.executable]
    return prefix + [script, impl, workload, path, fmt, timing]


def measure(cmd, reps, expected, timing="cold", extra_env=None):
    samples, peaks = [], []
    for _ in range(reps):
        result = run_once(cmd, extra_env)
        if result["rc"]:
            raise RuntimeError(result["err"] or f"engine exited {result['rc']}")
        raw = json.loads(result["out"])
        payload = {"rows": raw} if isinstance(raw, int) else raw
        for key, value in expected.items():
            if payload.get(key) != value:
                raise ValueError(f"{key}: expected {value}, got {payload.get(key)}")
        samples.append(result["secs"] if timing == "cold" else payload["query_secs"])
        peaks.append(result["rss_mb"])
    return statistics.median(samples), statistics.median(peaks)


def dependencies(node_modules):
    availability = {"libscanio-python": True, "native-python": True,
                    "libscanio-cli": os.path.exists(CLI)}
    versions = {"python": platform.python_version(), "platform": platform.platform()}
    for mod in ("pyarrow", "polars"):
        p = subprocess.run([sys.executable, "-c", f"import {mod}; print({mod}.__version__)"],
                           capture_output=True, text=True)
        availability[mod] = p.returncode == 0
        versions[mod] = p.stdout.strip() if p.returncode == 0 else "not installed"
    has_node = bool(shutil.which("node"))
    availability.update({"libscanio-node": has_node, "native-node": has_node})
    availability["apache-arrow"] = False
    if has_node:
        versions["node"] = subprocess.check_output(["node", "--version"], text=True).strip()
        env = dict(os.environ)
        if node_modules:
            env["NODE_PATH"] = os.path.abspath(node_modules)
        probe = subprocess.run(["node", "-e", "require('apache-arrow'); require('csv-parse/sync')"],
                               cwd=os.path.join(REPO, "bench"), env=env, capture_output=True)
        availability["apache-arrow"] = probe.returncode == 0
    return availability, versions


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rows", type=int, default=500_000)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--summary")
    ap.add_argument("--engines", help="comma-separated IDs: libscanio-cli,libscanio-python,libscanio-node,pyarrow,polars,apache-arrow,native-python,native-node")
    ap.add_argument("--workloads", default="count,arrow,stream")
    ap.add_argument("--timing", choices=("cold", "both"), default="both",
                    help="both adds a warm query measurement in a separate process; CLI has no warm mode")
    ap.add_argument("--max-rss-mb", type=float)
    ap.add_argument("--allow-debug", action="store_true")
    ap.add_argument("--node-modules", default=os.environ.get("LIBSCANIO_BENCH_NODE_MODULES", ""))
    args = ap.parse_args()
    if args.rows < 1 or args.reps < 1:
        ap.error("--rows and --reps must be positive")
    workloads = args.workloads.split(",")
    if not workloads or any(w not in WORKLOADS for w in workloads):
        ap.error("--workloads must select count,arrow,stream")
    known = {e for entries in ENGINES.values() for e, _ in entries}
    selected = set(args.engines.split(",")) if args.engines else known
    if selected - known or not any(e in selected for w in workloads for e, _ in ENGINES[w]):
        ap.error("--engines must select known IDs present in the selected workloads")
    if any(e.startswith("libscanio") for e in selected):
        sys.path.insert(0, os.path.join(REPO, "python"))
        import libscanio
        mode = libscanio.build_mode()
        if mode != "ReleaseFast" and not args.allow_debug:
            ap.error(f"libscanio is {mode}; rebuild c-lib/node/cli with -Doptimize=ReleaseFast")
    availability, versions = dependencies(args.node_modules)
    env = {"NODE_PATH": os.path.abspath(args.node_modules)} if args.node_modules else None
    results, lines = [], []
    failed = False

    def emit(line=""):
        print(line, flush=True)
        lines.append(line)

    emit("# Equivalent-work benchmark matrix")
    emit("\nCold: process startup + imports + query + exit. Warm: second query after one untimed query; imports excluded. CLI warm: N/A.")
    emit("Peak RSS (MiB): cold process, including runtime and imports. OS file cache is not cleared; cold means process, not disk.")
    emit("Eight string columns in both formats. Engine default threading; no common thread cap. Compare within a workload only.")
    emit("\nVersions: " + ", ".join(f"{k}={v}" for k, v in versions.items()))
    with tempfile.TemporaryDirectory() as tmp:
        for fmt in ("csv", "ndjson"):
            path = write_fixture(tmp, args.rows, fmt)
            emit(f"\n## {fmt.upper()} — {args.rows:,} rows, {os.path.getsize(path) / 1e6:.1f} MB, WHERE {WHERE}")
            for workload in workloads:
                expected = expected_result(args.rows, workload)
                emit(f"\n### {WORKLOADS[workload]}\n")
                emit("| engine | cold process | warm query | cold peak RSS | rows |")
                emit("|---|---|---|---|---|")
                for engine, label in ENGINES[workload]:
                    if engine not in selected:
                        continue
                    record = {"format": fmt, "workload": workload, "engine": engine,
                              "size_mb": os.path.getsize(path) / 1e6,
                              "rows_in_fixture": args.rows, "expected": expected}
                    if not availability[engine] or (workload == "arrow" and engine in ("libscanio-python", "polars") and not availability["pyarrow"]):
                        # Installed engines that fail are errors, not skips.
                        record.update(status="skipped", reason="dependency not installed")
                        if engine == "libscanio-cli":
                            record.update(status="failed", reason="CLI not built")
                            failed = True
                        emit(f"| {label} | {record['status']}: {record['reason']} | — | — | — |")
                        results.append(record)
                        continue
                    try:
                        cold, rss = measure(engine_command(engine, workload, path, fmt, "cold"),
                                            args.reps, expected, extra_env=env)
                        warm = None
                        if args.timing == "both" and engine != "libscanio-cli":
                            warm, _ = measure(engine_command(engine, workload, path, fmt, "warm"),
                                              args.reps, expected, timing="warm", extra_env=env)
                        over = bool(args.max_rss_mb and workload != "arrow" and
                                    engine in ("libscanio-cli", "libscanio-python") and rss > args.max_rss_mb)
                        failed |= over
                        record.update(status="failed" if over else "ok", cold_secs=cold,
                                      warm_secs=warm, rss_mb=rss, rows_matched=expected["rows"])
                        if over:
                            record["reason"] = "memory ceiling exceeded"
                        warm_text = f"{warm * 1000:.1f}ms" if warm is not None else "—"
                        emit(f"| {label} | {cold * 1000:.1f}ms | {warm_text} | {rss:.1f} MiB{' (OVER LIMIT)' if over else ''} | {expected['rows']:,} |")
                    except (RuntimeError, ValueError, OSError, KeyError) as exc:
                        failed = True
                        reason = str(exc).replace("\n", " ").replace("|", "/")
                        record.update(status="failed", reason=reason)
                        emit(f"| {label} | FAILED: {reason[:180]} | — | — | — |")
                    results.append(record)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump({"schema_version": 2, "versions": versions, "reps": args.reps,
                       "timing": args.timing, "results": results}, f, indent=2)
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
