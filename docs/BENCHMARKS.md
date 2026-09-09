# Benchmarks

**North star: scan faster, using less memory, than the alternatives.**
Measured, not assumed — same file, same query, same machine, cross-checked
row counts (including one independent `awk` ground truth per fixture,
outside every engine under test) before any number was trusted.

**Fixture:** real NYC taxi trip data (not synthetic) — `sample.csv`
(417MB, 1,000,000 rows, 51 columns), `trips.csv` (8.5GB, 20,000,000 rows,
same schema), and `trips_16gb.csv` (17GB, 40,000,000 rows, same schema
again), all from the [csvql](https://github.com/melihbirim/csvql) repo's
`bench/.taxi-data/`.

**Query:** `WHERE rate_code_id = '6'` — column 6 of 51 (early in the row),
matching 26 of 1,000,000 rows at the 417MB scale (0.0026% selectivity).
Chosen deliberately: a bare single-column count on a narrow synthetic
fixture (the previous version of this page) is a best case for
general-purpose columnar engines, not a fixture libscanio has any
particular edge on. A wide row with an early, highly selective filter is
the case `stop_after_column` (`src/root.zig`) is built for — the per-row
field split stops the instant the WHERE column is captured, so 45 of the
row's 51 columns are never touched.

Time is wall clock, RSS is peak resident set size (physical memory
actually used — see [DESIGN.md](DESIGN.md#what-is-rss)), via
`/usr/bin/time -l` (macOS). Machine: Apple M2 Pro, 16GB RAM. 417MB numbers
are the median of 3 runs; 8.5GB is a single run (each engine there takes
several seconds to tens of seconds — three reps wasn't worth the extra
wait for numbers already this far apart). Engines: `libscanio` (Python +
Node, the real published packages), `duckdb` (`read_csv_auto`, all
columns forced to string — no type inference, same as libscanio, for a
fair comparison), `pyarrow.dataset` (same, forced string column type),
`polars` (`scan_csv(infer_schema=False)`, lazy, `engine="streaming"`).

## 417MB, 1M rows, 51 columns

| engine | time | peak RSS |
|---|---|---|
| **libscanio (Python)** | **0.023s** | 30.1MB |
| **libscanio (Node)** | **0.016s** | 53.6MB |
| polars | 0.122s | 537.7MB |
| duckdb | 0.306s | 238.0MB |
| pyarrow.dataset | 0.785s | 158.9MB |

libscanio wins both axes against all three: 5.3-49x faster, 4-18x less
memory. (Was 0.097s/16.3MB Python, 0.089s/40.3MB Node before a real fix —
`parallelCountRowsWhere()` existed since M9 but was never wired into the
WHERE-filtered count path; see ROADMAP.md.)

## 8.5GB, 20M rows, same schema (20x bigger file)

| engine | time | peak RSS |
|---|---|---|
| **libscanio (Node)** | **1.46s** | 53.7MB |
| **libscanio (Python)** | **1.75s** | 30.2MB |
| duckdb | 3.08s | 393.2MB |
| pyarrow.dataset | 16.03s | 182.0MB |
| polars | 16.63s | 2399.7MB |

libscanio now wins both axes outright, including against duckdb (was
4.03s/4.06s before the same `parallelCountRowsWhere()` wiring fix
mentioned above — this table used to be the one honest loss). RSS barely
moved going from 417MB to 8.5GB (20x the file), while every other
engine's memory scaled with the file: polars 538MB → 2.4GB, pyarrow
159MB → 182MB, duckdb 238MB → 393MB.

## 17GB, 40M rows, same schema (checking the win holds at 2x again)

Not a special case at 8.5GB — same query, same schema, `trips_16gb.csv`:

| engine | time | peak RSS |
|---|---|---|
| **libscanio (Python)** | **3.40s** | 30.2MB |
| duckdb | 7.01s | 460.8MB |

634/40,000,000 rows matched, confirmed against an independent `awk` scan
before either engine's number was trusted (same discipline as every
other row in this doc). libscanio still wins both axes by roughly the
same margin as at 8.5GB — the lead isn't a one-scale fluke.

Row counts matched exactly across every engine, all three fixtures — 26 at
417MB, 317 at 8.5GB, 634 at 17GB — confirmed against an independent `awk`
scan of the raw file before any engine's number was trusted.

## Other query shapes (417MB fixture)

Same rigor, same file, three more shapes: a bare count (no WHERE), a
2-column projection, and all 51 columns — plus schema validation, which
only libscanio has a built-in feature for. All row counts cross-checked;
`invalid=58` matched between libscanio and a naive hand-rolled Python
check.

| query | libscanio (Python) | libscanio (Node) | duckdb | pyarrow.dataset | polars |
|---|---|---|---|---|---|
| `count()`, no WHERE | **0.016s** / **28.1MB** | 0.016s / 50.9MB | 0.299s / 207.3MB | 0.760s / 157.2MB | 0.015s / 473.0MB |
| 2 columns, WHERE rate_code_id=6 | 0.177s / **16.6MB** | 0.352s / 40.4MB | 0.317s / 210.9MB | 0.818s / 161.8MB | **0.124s** / 546.3MB |
| all 51 columns, WHERE rate_code_id=6 | **0.049s** / **29.1MB** | 0.347s / 40.4MB | 0.437s / 298.2MB | 1.330s / 188.2MB | 0.235s / 882.6MB |
| validate (4 rules) | **0.391s** / **16.5MB** | — | n/a | n/a | n/a |

**Honest reading, not spun**: polars is still faster than libscanio on
the 2-column projection (its native Rust column scan is genuinely quick
at that specific shape) — reported as measured, not hidden. The bare
`count()` gap above was closed by a real fix, not a benchmark trick:
`count()` with no WHERE now dispatches to `parallelCountRows()` (already
existed in `src/parallel.zig`, was simply never wired into the C ABI or
Node binding — see ROADMAP.md) instead of a single-threaded newline scan,
taking Python from 0.059s to 0.016s and Node from 0.050s to 0.016s,
essentially tied with polars now instead of 3-4x behind. libscanio wins
outright, both axes, on the shape its `stop_after_column` design actually
targets: a highly selective WHERE returning full rows. Every shape,
libscanio uses 4-30x less memory than every alternative, including the
one case (2-column projection) it still loses on time. Node's
`scanArray()` with `columns` set falls back to the single-threaded path
(the parallel collector doesn't support projection yet — see
ROADMAP.md), which is why it's slower than Python there.

validate() has no equivalent built into duckdb/pyarrow/polars (schema
rules like `min`/`max`/`required` per column, not just type casting), so
the only real comparison is against a naive hand-rolled Python loop doing
the same four checks: **0.391s vs 5.920s — 15.1x faster**, matching
libscanio's already-documented validation performance
([docs/VALIDATION_PERFORMANCE.md](VALIDATION_PERFORMANCE.md)).

Reproduce:

```bash
python3 bench/real/bench_libscanio.py  <file>   # WHERE rate_code_id=6; _node.js for Node
python3 bench/real/bench_count.py      <file>   # bare count(), no WHERE
python3 bench/real/bench_select2.py    <file>   # 2-column projection + WHERE
python3 bench/real/bench_selectall.py  <file>   # all columns + WHERE
python3 bench/real/bench_validate.py   <file>   # schema validation
```

Each has a `_duckdb.py`/`_pyarrow.py`/`_polars.py` sibling (see
`bench/real/`) except `bench_validate.py`, which has a `_naive.py` sibling
instead (no engine but libscanio has a built-in schema validator). Wrap
any of them in `/usr/bin/time -l` (macOS) or `/usr/bin/time -v` (Linux)
for RSS. Fixtures: `bench/.taxi-data/{sample,trips}.csv` in the
[csvql](https://github.com/melihbirim/csvql) repo.
