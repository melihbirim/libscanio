# Benchmarks

Machine: Apple M2 Pro, 16GB RAM, macOS. Single-threaded unless noted.
All numbers below: 10 runs each, `/usr/bin/time -l` (macOS,
wall time + peak RSS), min/avg/max reported. Same machine, same file, same
query, same result count verified across every tool before timing — never
trust a number the correctness check didn't back up first. Numbers here
are relative, not absolute — a different CPU, disk, or OS page cache state
will shift the raw seconds; the *ratios* between tools on the same machine
are the part worth trusting.

Primary fixture: `bench/.taxi-data/sample.csv` from the
[csvql](https://github.com/melihbirim/csvql) repo — 417MB, 1,000,000 rows,
51 real NYC taxi columns. A real, already-existing fixture, not synthetic
data generated to make a number look good.

## Filtered scan: `WHERE cab_type = 'yellow'`

967,553 matching rows — confirmed identical across every tool below before
any timing ran. **Correction**: an earlier version of this table compared
libscanio *counting* matches (no output produced) against xan/qsv *writing
every matched row to stdout* — not the same operation, and it made
libscanio look faster than it actually is at this job. Numbers below are
the corrected, fair comparison: libscanio via `scan_array()` actually
collecting every matched row (both projected columns) into Python objects,
same as what xan/qsv's output represents.

| tool | time avg | RSS avg |
|---|---|---|
| libscanio `scan_array()` (collects every match) | 0.687s | ~24MB |
| xan `search -s cab_type -e yellow` (→ /dev/null) | 0.89s | 12.98MB |
| qsv `search --select cab_type ^yellow$` | 1.260s | 21.72MB |
| `grep -c ",yellow,"` (substring, count only — genuinely not comparable to the row-materializing tools above) | 3.069s | 1.49MB |

At this selectivity (97% of the file matches), libscanio wins — but see
the **selectivity crossover** section below: this result flips at low
selectivity, and that's the more important finding, not this one number.

xan and qsv are the fairest comparison — same weight class as libscanio
(narrow-purpose CSV tools, no SQL layer, no optimizer), real and actively
used, not strawmen.

`grep`'s comparison isn't fully apples-to-apples either: it's a substring
match against the raw line and only counts (doesn't materialize rows),
libscanio's WHERE is an exact match against one pre-split column.

## Selectivity crossover vs xan — and closing it

Benchmarking libscanio fairly against xan (a real Rust CSV tool, same
weight class) surfaced a real gap: at low selectivity, libscanio lost by
~1.35-1.5x. Root cause, confirmed with a pure-Zig benchmark
(`examples/collect_bench.zig`, no Python/ctypes layer at all, to rule that
out first before touching anything) — `splitInto()` split every one of a
row's 51 fields regardless of how many the query actually needed, so a
filter on an early column paid for splitting 51 fields to answer a
question that only needed 2-6 of them.

Fixed with `ScannerOptions.stop_after_column` (`src/root.zig`) — the
per-row split stops the instant it's captured the highest column index
anything will read, never scanning the rest of the line at all. Threaded
through the C ABI (`COptions.max_column`) and computed automatically in
the Python binding wherever it's safe (see ROADMAP.md for the full
design, including why `topk()` deliberately does NOT get this treatment —
it returns full rows, bounding it would silently truncate them).

| selectivity | file | column position | before | after | xan |
|---|---|---|---|---|---|
| low (26 / 1,000,000) | 417MB | early (col 5) | 0.45-0.48s | **0.13-0.18s** | 0.29-0.33s |
| low (1,085 / 1,000,000) | 417MB | mid (col 20) | 0.45s | **0.27-0.29s** | 0.29-0.30s |
| low (13,711 / 20,000,000) | 8.5GB | mid (col 20) | 9.76s | **6.52-6.60s** | 7.26s |
| high (967,553 / 1,000,000) | 417MB | mid (col 24) | — | 0.687s (unchanged, already won) | 0.89s |

Early-column result: libscanio now beats xan outright, ~2x, reversing the
original loss. Mid-column and 8.5GB-scale results: libscanio now wins
too, not just closes the gap. The late-column case (column 47 of 51)
shows no improvement — expected, almost the whole row still needs
splitting when the target column is near the end, so there's nothing to
skip. The win is real but bounded by how early the needed columns fall in
the schema; it's not a universal "libscanio is now always faster than
xan" claim, and the honest crossover data above is kept rather than
deleted now that one side of it improved.

## Full scan (every row, every column)

Same file, no filter — `cat`, a hand-rolled raw mmap+scalar-split ceiling,
libscanio's `Scanner`, and zcsv's zero-allocation parser (the closest
comparable third-party Zig CSV library — also zero-copy, also in-memory,
no allocator on the hot path).

| tool | time avg | RSS avg |
|---|---|---|
| `cat file > /dev/null` | ~0.34s | 1.43MB |
| **libscanio `Scanner`** | 0.568s | 2.17MB |
| raw mmap + scalar split (hand-rolled ceiling, no lib) | 0.516s* | 426.3MB |
| zcsv `zero_allocs.slice` (Zig, third-party) | 2.489s | 1462.7MB |
| csvql, `SELECT *`, single-thread | 1.70s | — |
| csvql, `SELECT *`, multi-thread (default) | 0.16s | — |

*First run of the raw-mmap ceiling was a 1.175s cold-cache outlier;
excluding it, raw mmap and libscanio's chunked `Scanner` are statistically
identical on time — the chunked-read wrapper adds no measurable overhead
over hand-rolled Zig, it just also bounds memory (see
[DESIGN.md](DESIGN.md)).

Against zcsv specifically: libscanio is ~5.5-6x faster and ~2.6x lighter
at zcsv's fastest (zero-allocation) parsing mode — not a niche win, zcsv is
real and actively maintained.

csvql's numbers are included for context, not as a fair single-thread
comparison: its 0.16s multi-thread result comes from spreading work across
~7-8 cores (`user` time ~1.2s against 0.16s wall), not from a faster
per-core scan — pinned to one thread, csvql is ~4x *slower* than
libscanio's `Scanner` on the identical file. libscanio has no parallel scan
path yet; that gap is the actual lever left on the table (see
[ROADMAP.md](../ROADMAP.md)'s M9 entry), not evidence libscanio's core loop
is behind.

## Scale: does RSS actually stay flat past 417MB?

Every number above used the 417MB fixture. The core claim is "bounded
regardless of file size" — worth checking against a file 20x bigger, not
just asserting it extrapolates. `bench/.taxi-data/trips.csv` (also from
csvql, same NYC taxi schema): 8.5GB, 20,000,000 rows.

| file | size | peak RSS |
|---|---|---|
| sample.csv | 417MB | ~2.2MB |
| trips.csv | 8.5GB | ~2.16-2.21MB (3 runs) |

20x the file size, same peak RSS. Throughput held steady too (~2.1M
rows/sec, raw unfiltered scan) — this file has a narrower/different column
set than the 51-col sample, so its raw rows/sec isn't directly comparable
to the filtered-scan numbers elsewhere in this doc, but the flat RSS is
the actual point being checked here.

## Full comparison at 8.5GB scale

Same schema as sample.csv, `trips.csv`, `WHERE payment_type = 'DIS'`,
13,711 matching rows out of 20,000,000 — confirmed identical across every
tool below.

| tool | time | peak RSS |
|---|---|---|
| naive Python (`csv.reader`, projected) | 103.983s | 15.6MB |
| **libscanio `scan_array()`** (after `stop_after_column`, see below) | 6.52-6.60s | 20.7MB |
| xan `search -s payment_type -e DIS` | 7.26s | 12.8MB |
| qsv `search --select payment_type ^DIS$` | 13.08s | 21.5MB |

Originally 9.76s here — see the **selectivity crossover** section below for
the fix (`stop_after_column`, bounding the per-row field split) that
brought this from behind xan to ahead of it. libscanio now beats naive
Python by ~15.8x and xan by ~1.1x. Naive Python's lower RSS here still isn't a libscanio weakness —
this is a selective query, so neither approach ever holds the file in
memory; the "bounded regardless of file size" property is about the
internal scan loop, proven separately above, not about beating an
already-small Python footprint.

## Memory: chunked reads vs mmap/full-load

See [DESIGN.md](DESIGN.md) for the full chunked-read rationale and the
CSV/NDJSON/JSON-array before-and-after numbers (196x, 29x, and 26x less
peak RSS respectively, at 0-50% time cost depending on format).

## Ecosystem comparison — equivalent workloads

`bench/compare.py` separates three contracts. Compare engines **within a
category**, rather than treating a count, a Python iterator, and an Arrow
table as interchangeable outputs.

| Category | Required result | Engines |
|---|---|---|
| Filtered count | One scalar count; no matching table collected | libscanio CLI/Python/Node, PyArrow `count_rows`, Polars `select(pl.len())` |
| Materialized Arrow | All matching rows, all eight columns, string values, retained in an Arrow table | libscanio `scan_table(infer_types=False)`, PyArrow `to_table`, Polars `collect().to_arrow()`, optional Arrow JS + parser |
| Streaming import | Consume each matching row and all eight fields; sum their string lengths without retaining the result | libscanio Python/Node, Python csv/json, Node readline |

The Arrow group measures logical string columns (Arrow string or large
string), including conversion into Arrow where required. Both CSV and
NDJSON fixtures contain the same string values. This is an import/text
workload, **not a numeric analytics benchmark**. Type inference is disabled
or replaced with an explicit schema in the competing table readers.
The Node baseline parses only this fixture's unquoted CSV; it is not a
production CSV parser. Arrow JS includes CSV/JSON parsing and pivoting
objects into columns, so its label names that complete pipeline.

Each table reports two distinct timing boundaries:

- **Cold process:** launch, imports, query, output, and process exit.
- **Warm query:** a second query in a separate process after one untimed
  query; imports and warmup are excluded. Query construction and Arrow
  conversion are included. The CLI has no persistent query API, so its
  warm result is N/A.
- **Peak RSS (MiB):** the cold process's lifetime maximum, including
  runtime/import memory. Warm RSS is deliberately not mixed into it.

OS caches are not cleared: cold means a fresh process, not cold storage.
Every engine uses its default threading. Results are medians across
`--reps` fresh processes for each timing mode. Engines run sequentially;
small differences can reflect cache/order/CPU variation. No timing gate
is enforced in CI.

Every repetition must match an independent fixture-derived row count;
streaming consumers must also match a checksum covering every field.
Small-fixture tests check exact Arrow values across engines. An installed
engine failing, missing output, or any mismatch makes the run fail.
Unavailable optional dependencies are recorded as skipped. The 40 MiB CI
ceiling applies only to libscanio's CLI/Python count and streaming paths,
not materialized tables or the Node runtime.

Reproduce:

```bash
python -m pip install polars==1.44.1 pyarrow==25.0.1
zig build bench-compare -Doptimize=ReleaseFast -- --rows 200000 --reps 3
# Select a category or stable engine IDs:
python bench/compare.py --workloads arrow --engines libscanio-python,pyarrow,polars
# Optional JavaScript Arrow comparison:
npm install apache-arrow csv-parse
python bench/compare.py --node-modules ./node_modules
# Cold-only runs and machine-readable results:
python bench/compare.py --timing cold --json bench-results.json
```

JSON schema version 2 records workload, engine ID, status, cold/warm
seconds, cold RSS, fixture size/count, expected result, and runtime
versions. Summary Markdown uses the same categories. CI installs the
Python competitors and runs the matrix on Windows, macOS, and Linux.

A fresh local [categorized result snapshot](BENCHMARK_MATRIX.md) replaces
the old mixed-workload tables. Those historical numbers used different
consumption patterns and a numeric NDJSON fixture; they should not be
compared directly to this matrix or used to claim an overall winner.

API references: [Polars collect](https://docs.pola.rs/api/python/stable/reference/lazyframe/api/polars.LazyFrame.collect.html),
[PyArrow Dataset](https://arrow.apache.org/docs/python/generated/pyarrow.dataset.Dataset.html).

## Reproducing

```bash
zig build mem-check -Doptimize=ReleaseFast -- <file>              # raw Query scan, no filter
zig build filter-bench -Doptimize=ReleaseFast -- <file> <col> <val>  # WHERE eq scan, counts matches
```

Both print `matches=N time=Xs`; wrap in `/usr/bin/time -l` for RSS.

## Code placement moves the CSV numbers by up to 30%

The CSV scan benchmarks are alignment-sensitive to a degree that makes
small deltas meaningless. Appending N no-op exported functions to
`src/root.zig` — code the CSV path never calls, deterministic ReleaseFast
builds each time, medians of 7 interleaved runs on the 166MB fixture —
moves `scan-file` like this:

| no-op fns added | 0 | 2 | 4 | 6 | 8 | 10 |
|---|---|---|---|---|---|---|
| scan-file | 0.214s | 0.184s | 0.167s | 0.174s | 0.217s | 0.182s |

Nothing about the CSV scanner changed across those six builds. The hot
loop's address moves, and with it which side of a cache line its backward
branch lands on.

This is not theoretical: an NDJSON-only change (fusing the fast path's two
per-string scans, which CSV never executes) appeared to make CSV 22%
slower, purely because HEAD happened to land on an unlucky offset while
its parent landed on a lucky one.

**So when reading a CSV delta here, a difference under ~30% between two
single builds is not a result.** Before believing one:

1. Build each revision straight from git (`git checkout <rev> -- src`),
   never from a working tree that experiments have touched — stale
   binaries from a dirty tree caused exactly this confusion once already.
2. Interleave the runs of the two binaries rather than running all of A
   then all of B; the machine drifts.
3. For anything below ~30%, re-measure with 2-3 layout perturbations (the
   no-op-function trick above) and compare the ranges, not two points.

NDJSON and the parallel paths are far less sensitive — their deltas track
real changes and reproduce across perturbations.

Forcing the issue with `align(64)` on `Scanner.next`/`nextLine`/
`splitInto` does collapse the spread to under 2% — but it pins the loop at
0.216s, the slow end of its own range, versus 0.165s at `align(32)`. A
permanent ~25% cost to make a benchmark tidy is the wrong trade, so the
code is deliberately left unaligned and the caveat lives here instead.
