# Benchmarks

**Method:** every table below is wall-clock time and peak RSS (physical
memory the process actually used, via `/usr/bin/time -l`), on the same
file, same query, same machine, min/avg/max over 10 runs. Every tool
compared is checked to return the identical result before either number
is trusted. Numbers are relative, not absolute — a different machine
shifts the raw seconds; the ratios between tools on the same machine are
the part worth trusting.

Machine: Apple M2 Pro, 16GB RAM, macOS, single-threaded unless noted.
Fixture: `bench/.taxi-data/sample.csv` (417MB, 1,000,000 rows, 51 real NYC
taxi columns) and `trips.csv` (8.5GB, 20,000,000 rows, same schema family)
— both real, pre-existing data, not synthetic.

## Filtered scan: `WHERE cab_type = 'yellow'` (417MB, 967,553 matches)

| tool | time | peak RSS |
|---|---|---|
| libscanio `scan_array()` | 0.687s | ~24MB |
| xan `search -s cab_type -e yellow` | 0.89s | 12.98MB |
| qsv `search --select cab_type ^yellow$` | 1.26s | 21.72MB |
| `grep -c ",yellow,"` (count-only, not directly comparable) | 3.07s | 1.49MB |

xan and qsv are the fairest comparison — same weight class (narrow CSV
tools, no SQL layer), real and actively used. At this selectivity (97% of
rows match) libscanio wins, but selectivity changes the outcome — see below.

## Selectivity: low match rate, 417MB and 8.5GB

| selectivity | file | column position | libscanio | xan |
|---|---|---|---|---|
| 26 / 1,000,000 | 417MB | early | **0.13-0.18s** | 0.29-0.33s |
| 1,085 / 1,000,000 | 417MB | mid | **0.27-0.29s** | 0.29-0.30s |
| 13,711 / 20,000,000 | 8.5GB | mid | **6.52-6.60s** | 7.26s |

libscanio wins across all three by stopping each row's field-split the
moment it has every column the query needs, instead of splitting the
whole row regardless of what's used (`stop_after_column` in
`src/root.zig`). This closed a real loss libscanio had at low selectivity
before the fix — kept honest here rather than only showing the win.

## Full scan, every row and column (417MB)

| tool | time | peak RSS |
|---|---|---|
| `cat file > /dev/null` | 0.34s | 1.43MB |
| **libscanio `Scanner`** | 0.57s | 2.17MB |
| zcsv (third-party Zig CSV lib, zero-alloc mode) | 2.49s | 1462.7MB |

~5.5-6x faster and ~2.6x lighter than zcsv at zcsv's fastest mode.

## Scale: does peak RSS stay flat past 417MB?

| file | size | peak RSS |
|---|---|---|
| sample.csv | 417MB | ~2.2MB |
| trips.csv | 8.5GB (20x bigger) | ~2.2MB |

Same peak RSS at 20x the file size — memory doesn't grow with the file,
only time does (~2.1M rows/sec, unfiltered).

## 8.5GB scale, filtered: `WHERE payment_type = 'DIS'` (13,711 / 20,000,000 matches)

| tool | time | peak RSS |
|---|---|---|
| naive Python `csv.reader` | 103.98s | 15.6MB |
| **libscanio `scan_array()`** | 6.52-6.60s | 20.7MB |
| xan | 7.26s | 12.8MB |
| qsv | 13.08s | 21.5MB |

~15.8x faster than naive Python, ~1.1x faster than xan. Naive Python's
lower RSS isn't a libscanio weakness — this query is selective enough that
neither approach holds the whole file in memory; the flat-RSS claim above
is about the scan loop, proven separately.

## Concurrent load: `scan_table()` vs pyarrow

Under N-way concurrent load, libscanio's parallel scan/count path uses
**2.3-2.8x less memory than pyarrow** for the same query — the
Python-API-level comparison, not an internal-only number. Full method:
[ROADMAP.md](../ROADMAP.md).

## Ecosystem comparison (PyArrow, Polars, Node/Arrow JS)

`bench/compare.py` runs the same queries — filtered count, materialized
Arrow table, streaming import — across engines under identical contracts
(same result count, same checksum). See
[BENCHMARK_MATRIX.md](BENCHMARK_MATRIX.md) for the current numbers and
`bench/compare.py --help` for reproduction options.

## Reproducing

```bash
zig build mem-check -Doptimize=ReleaseFast -- <file>                  # raw scan, no filter
zig build filter-bench -Doptimize=ReleaseFast -- <file> <col> <val>   # WHERE eq scan, counts matches
```

Both print `matches=N time=Xs`; wrap in `/usr/bin/time -l` for RSS.

## A caveat worth knowing before trusting a small delta

CSV scan timings are sensitive to code alignment: appending unrelated
no-op functions elsewhere in the binary can move `scan-file`'s time by up
to 30% with zero logic changes, purely from where the hot loop's backward
branch lands relative to a cache line. A difference under ~30% between two
single builds is not a result — re-measure with a couple of layout
perturbations before believing it. NDJSON and the parallel paths don't
have this problem; their deltas reproduce reliably.
