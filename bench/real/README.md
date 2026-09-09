# Real-data benchmark suite

Backs [docs/BENCHMARKS.md](../../docs/BENCHMARKS.md). Real NYC taxi CSV
data, not synthetic — `sample.csv` (417MB/1M rows) and `trips.csv`
(8.5GB/20M rows), both 51 columns, from the
[csvql](https://github.com/melihbirim/csvql) repo's `bench/.taxi-data/`.

Primary query: `WHERE rate_code_id = '6'` — an early column (6 of 51),
low selectivity (26/1,000,000 rows at the 417MB scale) — the case
`stop_after_column` is built for, not a bare narrow-column count.

## Query shapes, one file family per shape

| shape | libscanio | duckdb | pyarrow | polars | naive |
|---|---|---|---|---|---|
| WHERE rate_code_id=6, count only | `bench_libscanio.py` / `_node.js` | `bench_duckdb.py` | `bench_pyarrow.py` | `bench_polars.py` | — |
| bare `count()`, no WHERE | `bench_count.py` / `_node.js` | `bench_count_duckdb.py` | `bench_count_pyarrow.py` | `bench_count_polars.py` | — |
| 2-column projection + WHERE | `bench_select2.py` / `_node.js` | `bench_select2_duckdb.py` | `bench_select2_pyarrow.py` | `bench_select2_polars.py` | — |
| all 51 columns + WHERE | `bench_selectall.py` / `_node.js` | `bench_selectall_duckdb.py` | `bench_selectall_pyarrow.py` | `bench_selectall_polars.py` | — |
| schema validation (4 rules) | `bench_validate.py` | n/a | n/a | n/a | `bench_validate_naive.py` |

```bash
python3 bench_select2.py <file>
python3 bench_select2_duckdb.py <file>
```

wrapped in `/usr/bin/time -l` (macOS) or `/usr/bin/time -v` (Linux) for
peak RSS. Needs `duckdb`, `pyarrow`, `polars` (`pip install duckdb
pyarrow polars`) and the built libscanio Python/Node packages (`zig build
python-extension`, `zig build node -Doptimize=ReleaseFast`).

Independently verify any row count against the raw file before trusting
an engine's number:

```bash
awk -F, 'NR>1 && $6=="6"{c++} END{print c+0}' <file>
```
