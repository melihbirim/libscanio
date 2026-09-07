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

## Ecosystem comparison — reproducible

Everything below comes from `zig build bench-compare` (see
[bench/compare.py](../bench/compare.py)), not from a script that no longer
exists. Every engine answers the same question in its own fresh process —
"how many rows match `cab_type = yellow`" — so the time includes runtime
startup and the peak RSS is that engine's alone, read from the OS rather
than self-reported. All nine agree on the row count; the harness fails if
they don't, because a fast wrong answer is not a result.

`native python` (the `csv`/`json` modules) and `native node` (`fs` +
`split`) are in the table on purpose: they are what you write when you
skip the library entirely, and they are the floor any dependency has to
beat to justify itself.

Reproduce:

```bash
zig build bench-compare -Doptimize=ReleaseFast -- --rows 1000000 --reps 5
# apache-arrow is skipped unless you point the harness at it:
npm install apache-arrow csv-parse
zig build bench-compare -Doptimize=ReleaseFast -- --node-modules ./node_modules
```

Measured on the machine in the header of this file, Zig 0.15.2,
pyarrow 25.0.1, polars 1.44.1, apache-arrow 21.2.0, Node 22, Python 3.11.

## CSV — 1,000,000 rows, 43MB, WHERE cab_type = yellow

| engine | time | peak RSS | rows |
|---|---|---|---|
| libscanio CLI (zig) | 106.4ms | 10.2MB | 333,334 |
| libscanio python | 1187.3ms | 10.2MB | 333,334 |
| libscanio python (arrow) | 229.0ms | 90.9MB | 333,334 |
| libscanio node | 899.6ms | 68.7MB | 333,334 |
| pyarrow | 438.7ms | 144.7MB | 333,334 |
| polars | 312.9ms | 163.7MB | 333,334 |
| apache-arrow (node) | 9028.2ms | 655.5MB | 333,334 |
| native python (csv/json) | 2207.8ms | 10.2MB | 333,334 |
| native node (split) | 903.9ms | 174.7MB | 333,334 |

## NDJSON — 1,000,000 rows, 139MB, WHERE cab_type = yellow

| engine | time | peak RSS | rows |
|---|---|---|---|
| libscanio CLI (zig) | 324.5ms | 10.2MB | 333,334 |
| libscanio python | 1417.9ms | 10.2MB | 333,334 |
| libscanio python (arrow) | 302.0ms | 91.7MB | 333,334 |
| libscanio node | 1210.3ms | 68.7MB | 333,334 |
| pyarrow | 650.7ms | 205.2MB | 333,334 |
| polars | 457.0ms | 231.3MB | 333,334 |
| apache-arrow (node) | 4909.1ms | 695.2MB | 333,334 |
| native python (csv/json) | 3410.9ms | 10.2MB | 333,334 |
| native node (split) | 1914.1ms | 306.5MB | 333,334 |

Reading these: libscanio's streaming paths hold **10.2MB regardless of
format or file size** while every other engine's memory scales with the
result — that gap, not the wall-clock column, is the thing the design
buys. On time, the CLI wins outright because below ~100MB starting the
runtime costs more than the scan; the Python streaming client is the
slowest libscanio path by design, paying a ctypes crossing per row to
keep memory flat. Node's ~69MB floor is V8's, not libscanio's.

`apache-arrow` (JS) has no native CSV or NDJSON reader, so its row has to
fully materialise every record as a JS object and then pivot to columns —
a structurally heavier pipeline than pyarrow's parse-straight-to-buffers
path, which is why it is an order of magnitude behind rather than a
tuning difference.

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
