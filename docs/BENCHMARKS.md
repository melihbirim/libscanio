# Benchmarks

All numbers below: 10 runs each, `/usr/bin/time -l` (macOS, wall time + peak
RSS), min/avg/max reported. Same machine, same file, same query, same
result count verified across every tool before timing — never trust a
number the correctness check didn't back up first.

Primary fixture: `bench/.taxi-data/sample.csv` from the
[csvql](https://github.com/melihbirim/csvql) repo — 417MB, 1,000,000 rows,
51 real NYC taxi columns. A real, already-existing fixture, not synthetic
data generated to make a number look good.

## Filtered scan: `WHERE cab_type = 'yellow'`

967,553 matching rows — confirmed identical across every tool below before
any timing ran.

| tool | time avg | RSS avg | vs libscanio |
|---|---|---|---|
| **libscanio** (single-thread, WHERE eq on one column) | **0.434s** | **2.21MB** | 1x |
| xan `search -s cab_type -e yellow` | 0.874s | 12.98MB | 2.0x slower, 5.9x more RSS |
| qsv `search --select cab_type ^yellow$` | 1.260s | 21.72MB | 2.9x slower, 9.8x more RSS |
| DuckDB, default (multi-thread, ~3-4 cores) | 0.774s | 203.77MB | 1.8x slower *despite* threads, 92x more RSS |
| DuckDB, `--threads=1` | 2.459s | 92.80MB | 5.7x slower, 42x more RSS |
| `grep -c ",yellow,"` (substring, not column-aware) | 3.069s | 1.49MB | 7.1x slower, RSS comparable |

xan and qsv are the fairest comparison — same weight class as libscanio
(narrow-purpose CSV tools, no SQL layer, no optimizer), real and actively
used, not strawmen. libscanio still wins outright on both axes. One
asterisk: xan/qsv write full matched rows to stdout, libscanio's bench only
counts — a real difference in work done, though not enough on its own to
explain a 2-3x gap.

DuckDB is a different weight class entirely (full SQL engine, optimizer,
joins, spilling, dozens of formats) — losing to it on wall-clock even while
DuckDB throws multiple cores at the problem isn't "libscanio beats DuckDB"
as a general claim, it's confirmation that a purpose-built scanner doesn't
need to pay for machinery a single filtered scan never uses.

`grep`'s comparison isn't fully apples-to-apples either: it's a substring
match against the raw line, libscanio's WHERE is an exact match against one
pre-split column — real structural leverage, not a trick, but also exactly
why it wins.

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
rows/sec) — this file has a narrower/different column set than the 51-col
sample, so its rows/sec isn't directly comparable to the filtered-scan
numbers above, but the flat RSS is the actual point being checked here.

## Memory: chunked reads vs mmap/full-load

See [DESIGN.md](DESIGN.md) for the full chunked-read rationale and the
CSV/NDJSON/JSON-array before-and-after numbers (196x, 29x, and 26x less
peak RSS respectively, at 0-50% time cost depending on format).

## Reproducing

```bash
zig build mem-check -Doptimize=ReleaseFast -- <file>              # raw Query scan, no filter
zig build filter-bench -Doptimize=ReleaseFast -- <file> <col> <val>  # WHERE eq scan, counts matches
```

Both print `matches=N time=Xs`; wrap in `/usr/bin/time -l` for RSS.
