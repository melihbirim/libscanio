#!/usr/bin/env python3
"""Ecosystem comparison: libscanio's three front doors against pyarrow,
polars, apache-arrow, and hand-written baselines, on one fixture and one
query.

Committed as a permanent tool rather than a throwaway script, because the
numbers in ROADMAP.md and docs/BENCHMARKS.md were previously produced
ad-hoc and cannot be re-derived by anyone else. Every engine here answers
the SAME question — "how many rows match this filter, and what did it
cost to find out" — in one fresh process, so wall time includes runtime
startup and peak RSS is that engine's alone.

Two deliberate choices worth knowing before quoting anything it prints:

  * Whole-process timing, not an inner timer. Below ~100MB the dominant
    cost of a query is starting the runtime, not scanning; an inner timer
    hides the difference that actually decides whether a small query is
    fast. Where an engine's own scan time matters separately, run it with
    --inner.

  * Peak RSS is the maximum resident set of the child process, read from
    the OS (ru_maxrss via wait4), not a number the engine reports about
    itself.

Baselines are included on purpose: "native python" (the csv module) and
"native node" (fs + split) are what a developer writes when they don't
reach for a library at all, and they are the honest floor an engine has
to beat to justify its dependency.

Usage:
    python3 bench/compare.py                     # default fixture sizes
    python3 bench/compare.py --rows 2000000      # bigger fixture
    python3 bench/compare.py --json out.json     # machine-readable too
    python3 bench/compare.py --engines libscanio-cli,pyarrow

Optional engines are skipped with a note if their dependency is missing,
so this runs anywhere; only the libscanio engines and the native
baselines are required.
"""
import argparse
import json
import os
import shutil
import statistics
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
# Each engine runs in its own process and reports "ROWS=<n>" on stdout.
# The row count is checked across engines: a fast wrong answer is not a
# result, and this is the only thing keeping an engine from "winning" by
# quietly skipping work.

RUNNER = r"""
import json, resource, subprocess, sys, time
cmd = json.loads(sys.argv[1])
t0 = time.monotonic()
p = subprocess.run(cmd, capture_output=True, encoding="utf-8", errors="replace")
el = time.monotonic() - t0
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024.0
print(json.dumps({"secs": el, "rss_mb": rss, "out": p.stdout, "err": p.stderr[-400:], "rc": p.returncode}))
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
        return json.loads(p.stdout)
    finally:
        os.unlink(runner)


def measure(cmd, reps, extra_env=None):
    times, rss, rows, err = [], [], None, None
    for _ in range(reps):
        r = run_once(cmd, extra_env)
        if r["rc"] != 0:
            return None, None, None, (r["err"] or "non-zero exit").strip()
        for line in r["out"].splitlines():
            if line.startswith("ROWS="):
                rows = int(line[5:])
        if rows is None:
            # The CLI's own --count prints a bare number; it predates this
            # harness and shouldn't grow a marker just to be measured.
            tail = [ln for ln in r["out"].splitlines() if ln.strip()]
            if tail and tail[-1].strip().isdigit():
                rows = int(tail[-1].strip())
        times.append(r["secs"])
        rss.append(r["rss_mb"])
    return statistics.median(times), statistics.median(rss), rows, err


# ── engine scripts ────────────────────────────────────────────────────

PY_LIBSCANIO = r"""
import sys
sys.path.insert(0, sys.argv[2])
import libscanio
n = sum(1 for _ in libscanio.scan(sys.argv[1], where=sys.argv[3]))
print(f"ROWS={n}")
"""

PY_LIBSCANIO_TABLE = r"""
import sys
sys.path.insert(0, sys.argv[2])
import libscanio
print(f"ROWS={libscanio.scan_table(sys.argv[1], where=sys.argv[3]).num_rows}")
"""

PY_PYARROW = r"""
import sys, operator
import pyarrow.dataset as ds, pyarrow.compute as pc
path, fmt, col, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# pyarrow's name for line-delimited JSON is "json"; passing "ndjson"
# through raised a bare ArrowInvalid that looked like an engine failure.
t = ds.dataset(path, format="json" if fmt == "ndjson" else fmt).to_table(filter=pc.field(col) == val)
print(f"ROWS={t.num_rows}")
"""

PY_POLARS = r"""
import sys
import polars as pl
path, fmt, col, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lf = pl.scan_csv(path) if fmt == "csv" else pl.scan_ndjson(path)
print(f"ROWS={lf.filter(pl.col(col) == val).collect().height}")
"""

PY_NATIVE = r"""
import sys, csv, json
path, fmt, col, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
n = 0
if fmt == "csv":
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get(col) == val:
                n += 1
else:
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip() and json.loads(line).get(col) == val:
                n += 1
print(f"ROWS={n}")
"""

JS_LIBSCANIO = r"""
const ls = require(process.argv[3]);
(async () => {
  let n = 0;
  for await (const r of ls.scan(process.argv[2], { where: process.argv[4] })) n++;
  process.stdout.write(`ROWS=${n}\n`);
})();
"""

JS_ARROW = r"""
// apache-arrow (JS) ships no native CSV or NDJSON reader, so a table has
// to be built by fully materialising every row as a JS object first and
// then pivoting to columns — structurally heavier than pyarrow's
// parse-straight-to-Arrow-buffers path, not a tuning difference.
const fs = require('fs');
// Required by bare name (NODE_PATH is set by the harness): requiring by
// absolute path bypasses a package's exports map, which is exactly how
// csv-parse/sync failed to resolve here.
const arrow = require('apache-arrow');
const [, , file, fmt, col] = process.argv;
const val = process.argv[6];
let rows;
if (fmt === 'csv') {
  const { parse } = require('csv-parse/sync');
  rows = parse(fs.readFileSync(file), { columns: true });
} else {
  rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(JSON.parse);
}
const keep = rows.filter((r) => String(r[col]) === val);
const cols = {};
for (const k of Object.keys(keep[0] || {})) cols[k] = keep.map((r) => String(r[k]));
const table = arrow.tableFromArrays(cols);
process.stdout.write(`ROWS=${table.numRows}\n`);
"""

JS_NATIVE = r"""
// What you write with no library at all: read, split, compare.
const fs = require('fs');
const [, , file, fmt, col, val] = process.argv;
const text = fs.readFileSync(file, 'utf8');
let n = 0;
if (fmt === 'csv') {
  const lines = text.split('\n');
  const header = lines[0].split(',');
  const idx = header.indexOf(col);
  for (let i = 1; i < lines.length; i++) {
    if (!lines[i]) continue;
    if (lines[i].split(',')[idx] === val) n++;
  }
} else {
  for (const line of text.split('\n')) {
    if (line && JSON.parse(line)[col] === val) n++;
  }
}
process.stdout.write(`ROWS=${n}\n`);
"""


def write_scripts(tmp):
    paths = {}
    for name, body in (("py_libscanio.py", PY_LIBSCANIO), ("py_libscanio_table.py", PY_LIBSCANIO_TABLE),
                       ("py_pyarrow.py", PY_PYARROW), ("py_polars.py", PY_POLARS),
                       ("py_native.py", PY_NATIVE), ("js_libscanio.js", JS_LIBSCANIO),
                       ("js_arrow.js", JS_ARROW), ("js_native.js", JS_NATIVE)):
        p = os.path.join(tmp, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(body)
        paths[name] = p
    return paths


# ── fixtures ──────────────────────────────────────────────────────────


def write_fixture(tmp, rows, fmt):
    cabs = ["yellow", "green", "blue"]
    path = os.path.join(tmp, f"bench.{'csv' if fmt == 'csv' else 'ndjson'}")
    with open(path, "w", encoding="utf-8") as f:
        if fmt == "csv":
            f.write("trip_id,cab_type,passengers,distance,fare,tip,total,vendor\n")
            for i in range(rows):
                f.write(f"{600000000 + i},{cabs[i % 3]},{i % 6 + 1},{(i % 997) / 10.0},"
                        f"{(i % 523) + 2.5},{(i % 37) / 4.0},{(i % 600) + 5.25},V{i % 4}\n")
        else:
            for i in range(rows):
                f.write(json.dumps({
                    "trip_id": 600000000 + i, "cab_type": cabs[i % 3], "passengers": i % 6 + 1,
                    "distance": (i % 997) / 10.0, "fare": (i % 523) + 2.5,
                    "tip": (i % 37) / 4.0, "total": (i % 600) + 5.25, "vendor": f"V{i % 4}",
                }) + "\n")
    return path


def have_python_module(mod):
    return subprocess.run([sys.executable, "-c", f"import {mod}"], capture_output=True).returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=500_000)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--engines", help="comma-separated subset")
    ap.add_argument("--max-rss-mb", type=float,
                    help="fail if a libscanio streaming engine exceeds this peak RSS. "
                         "The bounded-memory claim is the one property here that is NOT "
                         "noisy on a shared runner, so it is the one worth gating on.")
    ap.add_argument("--summary", help="also append the tables to this file (GITHUB_STEP_SUMMARY)")
    ap.add_argument("--allow-debug", action="store_true",
                    help="run even though libscanio was not built in ReleaseFast. "
                         "For checking the harness itself; never for a published number.")
    ap.add_argument("--node-modules", default=os.environ.get("LIBSCANIO_BENCH_NODE_MODULES", ""),
                    help="directory holding apache-arrow and csv-parse (enables the Arrow/JS engine)")
    args = ap.parse_args()

    if not os.path.exists(CLI):
        print(f"missing {CLI} — run: zig build cli -Doptimize=ReleaseFast", file=sys.stderr)
        return 1

    # Refuse to publish a Debug number. `zig build diff-test`/`node`/`cli`
    # reinstall their artifacts at the DEFAULT optimize mode, silently
    # overwriting a ReleaseFast build in zig-out — a Debug library
    # measures orders of magnitude slower and looks like a real result.
    # This has produced wrong numbers more than once; it is cheaper to
    # fail here than to notice afterwards.
    sys.path.insert(0, os.path.join(REPO, "python"))
    try:
        import libscanio as _ls
        mode = _ls.build_mode()
    except Exception as e:  # noqa: BLE001 — library not built yet is its own message
        print(f"cannot load libscanio to check its build mode: {e}", file=sys.stderr)
        return 1
    if mode != "ReleaseFast" and not args.allow_debug:
        print(f"libscanio.so was built in {mode}, not ReleaseFast — refusing to publish "
              f"a benchmark from it. Run: zig build c-lib -Doptimize=ReleaseFast "
              f"(and node/cli likewise), or pass --allow-debug.", file=sys.stderr)
        return 1

    results = []
    lines = []

    def emit(text=""):
        print(text)
        lines.append(text)

    with tempfile.TemporaryDirectory() as tmp:
        s = write_scripts(tmp)
        node_index = os.path.join(REPO, "node", "index.js")
        py_dir = os.path.join(REPO, "python")
        nm = args.node_modules

        for fmt in ("csv", "ndjson"):
            path = write_fixture(tmp, args.rows, fmt)
            size_mb = os.path.getsize(path) / 1e6
            engines = [
                ("libscanio CLI (zig)", [CLI, path, "--where", WHERE, "--count"], True),
                ("libscanio python", [sys.executable, s["py_libscanio.py"], path, py_dir, WHERE], True),
                ("libscanio python (arrow)", [sys.executable, s["py_libscanio_table.py"], path, py_dir, WHERE],
                 have_python_module("pyarrow")),
                ("libscanio node", ["node", s["js_libscanio.js"], path, node_index, WHERE], bool(shutil.which("node"))),
                ("pyarrow", [sys.executable, s["py_pyarrow.py"], path, fmt, WHERE_COL, WHERE_VAL],
                 have_python_module("pyarrow")),
                ("polars", [sys.executable, s["py_polars.py"], path, fmt, WHERE_COL, WHERE_VAL],
                 have_python_module("polars")),
                ("apache-arrow (node)", ["node", s["js_arrow.js"], path, fmt, WHERE_COL, nm, WHERE_VAL],
                 bool(nm and os.path.isdir(os.path.join(nm, "apache-arrow"))), {"NODE_PATH": nm}),
                ("native python (csv/json)", [sys.executable, s["py_native.py"], path, fmt, WHERE_COL, WHERE_VAL], True),
                ("native node (split)", ["node", s["js_native.js"], path, fmt, WHERE_COL, WHERE_VAL],
                 bool(shutil.which("node"))),
            ]
            if args.engines:
                wanted = {e.strip() for e in args.engines.split(",")}
                engines = [e for e in engines if e[0] in wanted]

            emit(f"\n## {fmt.upper()} — {args.rows:,} rows, {size_mb:.0f}MB, WHERE {WHERE}\n")
            emit("| engine | time | peak RSS | rows |")
            emit("|---|---|---|---|")
            expected_rows = None
            for entry in engines:
                name, cmd, available = entry[0], entry[1], entry[2]
                extra_env = entry[3] if len(entry) > 3 else None
                if not available:
                    emit(f"| {name} | _skipped_ | | dependency not installed |")
                    continue
                t, rss, rows, err = measure(cmd, args.reps, extra_env)
                if t is None:
                    emit(f"| {name} | _failed_ | | {err[:60]} |")
                    continue
                if expected_rows is None:
                    expected_rows = rows
                mark = "" if rows == expected_rows else f" **MISMATCH (expected {expected_rows})**"
                emit(f"| {name} | {t * 1000:.1f}ms | {rss:.1f}MB | {rows:,}{mark} |")
                results.append({"format": fmt, "engine": name, "rows_in_fixture": args.rows,
                                "size_mb": round(size_mb, 1), "secs": t, "rss_mb": rss,
                                "rows_matched": rows, "agrees": rows == expected_rows})

    disagreements = [r for r in results if not r["agrees"]]
    if disagreements:
        emit("\n**Engines disagreed on the row count — the timings above are not comparable.**")
        for d in disagreements:
            emit(f"  {d['format']} {d['engine']}: {d['rows_matched']}")

    # The memory ceiling is the claim worth gating on: unlike wall time it
    # does not move with runner load, and "bounded regardless of input" is
    # the property the whole design exists to provide.
    # Only the engines whose memory libscanio actually controls: the CLI
    # and the streaming Python client. The Node client sits on V8's ~58MB
    # floor and the Arrow paths materialise by definition — holding those
    # to a streaming ceiling would be measuring someone else's runtime.
    GATED = ("libscanio CLI (zig)", "libscanio python")
    over = []
    if args.max_rss_mb:
        for r in results:
            if r["engine"] in GATED and r["rss_mb"] > args.max_rss_mb:
                over.append(r)
        if over:
            emit("")
            emit(f"**Peak RSS exceeded the {args.max_rss_mb}MB ceiling:**")
            for r in over:
                emit(f"  - {r['format']} {r['engine']}: {r['rss_mb']:.1f}MB")

    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2)
        print(f"\nwrote {args.json_out}")
    return 1 if (disagreements or over) else 0


if __name__ == "__main__":
    sys.exit(main())
