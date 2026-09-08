# Simple benchmark suite

Generates the fixtures and runs the engine comparisons behind
[docs/BENCHMARKS.md](../../docs/BENCHMARKS.md). Query is fixed:
`WHERE category = 'B'` (~20% selectivity) over `id,category,amount`.

## Generate fixtures

```bash
./gen_fixture.sh <rows> <out.csv>
./gen_fixture_ndjson.sh <rows> <out.ndjson>
```

Row counts used for the published numbers (approximate byte targets —
`amount`/`id` digit width grows with row count, so exact sizes vary):

| tier | CSV rows | NDJSON rows |
|---|---|---|
| 1MB | 72,522 | 23,450 |
| 10MB | 725,216 | 234,450 |
| 100MB | 7,252,158 | 2,344,450 |
| 1GB | 65,000,000 | 23,444,450 |
| 10GB | 620,000,000 | 234,444,480 |

## Run

```bash
./run_bench_fast.sh <fixture> <label> csv|json <reps>   # libscanio, pyarrow, pandas, polars, duckdb
./run_bench_all.sh  <fixture> <label> csv|json <reps>    # + naive Python/Node, apache-arrow
```

`run_bench_all.sh` includes naive Python (`csv.DictReader`), naive Node
(`readline`), and Node + `apache-arrow` (needs `npm install csv-parse
apache-arrow` in this directory first) — all three are too slow or
OOM-prone above ~100MB (see BENCHMARKS.md's footnotes), which is why
`run_bench_fast.sh` exists as the version actually used at 1GB/10GB.

Needs `pandas`, `polars`, `duckdb`, `pyarrow` (`pip install pandas polars
duckdb pyarrow`) and the built libscanio Python/Node packages
(`zig build python-extension`, `zig build node -Doptimize=ReleaseFast`).

Each `bench_*.py`/`bench_*.js` file also runs standalone:
`python3 bench_pyarrow.py <file> csv|json`.
