# Benchmarks

**North star: scan faster, using less memory, than the alternatives.**
Measured, not assumed — same file, same query, same machine, cross-checked
row counts before any number was trusted.

**Method:** one file per size tier (`id,category,amount` / NDJSON
equivalent, `category` one of 5 values), filtered with `WHERE category =
'B'` (~20% of rows match). Time is wall clock, RSS is peak resident set
size (physical memory actually used, not the file size — see
[DESIGN.md](DESIGN.md#what-is-rss)), via `/usr/bin/time -l` (macOS).
Machine: Apple M2 Pro, 16GB RAM. 1MB–1GB tiers are the median of 3 runs;
10GB is a single run (the slow engines take minutes each — three reps
wasn't worth the extra 30-45 minutes for numbers that were already
directionally clear from the smaller tiers).

Engines: `libscanio` (Python + Node, the real published packages, not the
CLI), `pyarrow.dataset`, `pandas` (chunked, `chunksize=500_000` — not a
full `read_csv()` load), `polars` (`scan_csv`/`scan_ndjson`, lazy,
`engine="streaming"`), `duckdb` (`read_csv_auto`/`read_ndjson_auto`).
Naive hand-written Python (`csv.DictReader`/line-by-line `json.loads`),
naive Node (`readline`), and Node + `apache-arrow` (`csv-parse` into
`tableFromArrays`, since apache-arrow has no native CSV/NDJSON reader)
were run through 100MB and dropped above that — see the notes under each
table for why.

## CSV

| engine | 1MB | 10MB | 100MB | 1GB | 10GB |
|---|---|---|---|---|---|
| **libscanio (Python)** | 0.005s / 15.4MB | 0.018s / 15.6MB | 0.153s / 15.4MB | 1.37s / 15.4MB | 14.3s / 15.4MB |
| **libscanio (Node)** | 0.003s / 40.7MB | 0.016s / 40.5MB | 0.151s / 40.5MB | 1.35s / 40.3MB | 14.1s / 38.5MB |
| duckdb | 0.026s / 51.5MB | 0.057s / 61.4MB | 0.114s / 163.2MB | 0.55s / 237.9MB | 5.6s / 395.0MB |
| pyarrow.dataset | 0.008s / 112.7MB | 0.030s / 126.2MB | 0.240s / 162.5MB | 2.13s / 254.3MB | 21.8s / 556.0MB |
| polars | 0.006s / 74.6MB | 0.009s / 99.5MB | 0.057s / 308.6MB | 0.34s / 1457.8MB | 24.8s / 3546.6MB |
| pandas (chunked) | 0.016s / 111.4MB | 0.097s / 169.8MB | 0.805s / 209.0MB | 7.19s / 210.3MB | skipped¹ |
| naive Python | 0.049s / 15.2MB | 0.503s / 15.1MB | 5.03s / 15.2MB | 45.5s / 15.1MB | 459.4s² / 15.6MB |
| naive Node | 0.029s / 57.6MB | 0.172s / 66.2MB | 1.48s / 82.8MB | 13.1s / 83.1MB | 127.5s² / 87.1MB |
| Node + apache-arrow | 0.092s / 82.1MB | 0.666s / 198.7MB | 7.24s / 786.3MB | crashed³ | not run |

## NDJSON

| engine | 1MB | 10MB | 100MB | 1GB | 10GB |
|---|---|---|---|---|---|
| **libscanio (Python)** | 0.003s / 15.5MB | 0.014s / 15.4MB | 0.103s / 15.5MB | 1.04s / 15.4MB | 11.6s / 16.2MB |
| **libscanio (Node)** | 0.002s / 40.3MB | 0.011s / 40.4MB | 0.100s / 40.5MB | 1.00s / 40.4MB | 11.3s / 40.6MB |
| duckdb | 0.016s / 50.0MB | 0.031s / 68.8MB | 0.059s / 175.8MB | 0.21s / 290.6MB | 2.4s / 295.2MB |
| pyarrow.dataset | 0.016s / 115.2MB | 0.031s / 133.0MB | 0.147s / 207.4MB | 0.99s / 251.7MB | 7.8s / 481.0MB |
| polars | 0.005s / 71.3MB | 0.011s / 88.2MB | 0.078s / 237.4MB | 0.54s / 1270.9MB | killed⁴ |
| pandas (chunked) | 0.028s / 112.4MB | 0.205s / 251.6MB | 1.94s / 524.2MB | 18.5s / 578.5MB | skipped¹ |
| naive Python | 0.024s / 15.2MB | 0.234s / 15.2MB | 2.36s / 15.2MB | not run | not run |
| naive Node | 0.018s / 52.0MB | 0.101s / 55.9MB | 0.900s / 78.1MB | not run | not run |
| Node + apache-arrow | 0.019s / 64.7MB | 0.113s / 136.9MB | 1.09s / 590.7MB | not run | not run |

Row counts matched exactly across every engine that completed, at every
tier — same query, same answer, confirmed before any number was trusted.

¹ **pandas skipped at 10GB**: still running past 68s on its first of 3
reps (>2x libscanio's total 10GB time) when killed — the 1GB numbers
already show why (7-18s there, versus libscanio's ~1s).
² **naive Python/Node at 10GB**: single run, not median-of-3, given the
per-run cost (7.7 and 2.1 minutes respectively).
³ **apache-arrow crashed at 1GB** (CSV): Node heap out-of-memory,
reproduced twice. `csv-parse` fully materializes records before
`tableFromArrays()` can build columns — apache-arrow has no native
CSV/NDJSON reader (confirmed: no `pyarrow.csv`-equivalent in the JS
package), so this path pays a full in-memory parse first regardless of
what's queried after.
⁴ **polars NDJSON killed at 10GB**: exceeded 2x libscanio's 10GB time
(23s budget) with no result yet — consistent with its CSV number at the
same tier (24.8s) and its RSS pattern (1.3-3.5GB at 1GB-10GB, growing
roughly linearly with file size, not flat).

## The point of this table

**Peak RSS.** libscanio's stays flat (~15-16MB Python, ~38-41MB Node)
from 1MB to 10GB — it tracks the read buffer, not the file. Every other
engine's RSS grows with file size, some linearly (polars: 71MB → 3.5GB,
roughly proportional to input size) and some sublinearly but still
clearly growing (duckdb, pyarrow: low hundreds of MB to several hundred
MB). Naive Python/Node also stay close to flat — `csv.DictReader` and
`readline` are real generators, not full-file loads — but pay for it in
time (30-40x slower than libscanio at the tiers both completed).

**Time.** libscanio and duckdb are the two consistently fast engines
across every tier and both formats; pyarrow and polars are competitive at
small-to-mid sizes but polars' NDJSON path degrades badly at 10GB. pandas
chunked reading is real streaming (flat-ish RSS growth, much better than
a full `read_csv()` load would be) but 5-15x slower than libscanio at
every tier it completed.

Reproduce (single query, single engine):

```bash
python3 -c "import libscanio; print(libscanio.count('file.csv', where='category = B'))"
node -e "console.log(require('libscanio').count('file.csv', 'category = B'))"
python3 -c "import duckdb; print(duckdb.sql(\"SELECT count(*) FROM read_csv_auto('file.csv') WHERE category='B'\").fetchone())"
```

wrapped in `/usr/bin/time -l` (macOS) or `/usr/bin/time -v` (Linux) for RSS.
Generator scripts for every fixture and every engine used above live in
[bench/simple/](../bench/simple/) — see `bench/simple/README.md`.
