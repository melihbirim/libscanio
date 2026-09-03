# Design

## Chunked reads, not mmap

CSV, NDJSON, and JSON arrays all read the source file through one fixed-size
buffer (256KB by default), reused for the whole scan — never mmap, never a
full-file load. Peak memory tracks the chunk size, not the file size: a
10GB file costs the same working set as a 10MB one.

This replaced an earlier mmap-based design. mmap gives zero-copy rows for
free, but scanning touches (and keeps resident) every page of the file — on
a 417MB/1M-row CSV, that measured 426MB peak RSS, same order as the file
itself. `cat` on the same file holds ~1.4MB (read a fixed chunk, discard,
repeat). Chunked reads get libscanio into that same bounded regime instead.

Almost every row is still a zero-copy slice into the current chunk — the
common case costs nothing extra. Only a row that straddles a chunk boundary
(rare, only near each chunk edge) gets copied into a small reused scratch
buffer instead. Same "valid until the next `next()` call" contract either
way, so this didn't change the API.

JSON arrays (`[{...},{...}]`) needed a different boundary rule than
NDJSON's newlines — no line breaks to rely on inside the array — so that
path tracks brace depth and in-string/escape state across chunk refills
instead, extracting one balanced `{...}` object at a time.

### Measured

10 runs each, `/usr/bin/time -l`, min/avg/max peak RSS and wall time.

| | file | old (mmap/load) | new (chunked) |
|---|---|---|---|
| CSV | 417MB / 1M rows | 427MB RSS, 0.46s | 2.2MB RSS, 0.56s |
| NDJSON | 56MB / 1M rows | 57.7MB RSS, 0.18s | 2.0MB RSS, 0.17s |
| JSON array | 11MB / 200K rows | 51.1MB RSS, 0.03s | 2.0MB RSS, 0.05s |

CSV: ~24% slower for a 196x memory win. NDJSON: same speed, 29x less
memory — line-splitting was never the bottleneck, JSON parsing dominates
either way. JSON arrays: ~50% slower for a 26x memory win — the streaming
brace-depth scan does more structural work per byte than the old one-pass
convert did.

Chunk size (256KB default) was swept, not guessed — 64KB/256KB/1MB/4MB/16MB
on the same CSV file. Time was flat from 64KB through 4MB (syscall count
isn't the bottleneck in that range); RSS scaled roughly linearly with chunk
size; 16MB was a strict loss on both axes. Configurable per call, not
hardcoded: `Scanner.openWithOptions(allocator, path, .{ .chunk_size = N })`
or `Query.open(allocator, path, .{ .csv_chunk_size = N })`.

## Allocator matters, measured

Pass `std.heap.c_allocator` to `Query.open()`, not `GeneralPurposeAllocator`
— on a 500K-row NDJSON file this was the difference between 42K and 2.78M
rows/sec (66x), independent of the parser used. GPA's per-allocation
tracking overhead dominates workloads with many small, short-lived
allocations; it's also unsafe to use in a `dlopen()`'d library regardless
of speed (its `PageAllocator` faults there — the C ABI uses `c_allocator`
for this reason too, so Python and other C ABI consumers get the fast path
automatically).

## Other work-not-done properties

- `count()` with no WHERE clause never parses a field — CSV and NDJSON both
  count line/object boundaries directly against the chunk buffer.
- `limit(N)` stops pulling from the source the instant N rows are found —
  cost is proportional to N, not file size.
- `aggregate()` computes count/sum/min/max/avg in one streaming pass,
  regardless of how many of the five are needed.
- `topK()` is O(N log K) — a min/max heap adapted from csvql's
  `TopKHeap`, not a full sort.

See [ROADMAP.md](../ROADMAP.md) for the milestone-by-milestone history behind
these numbers, including two real bugs the work surfaced (a segfault from
sharing an allocator across an arena boundary, and a ctypes signature gap
that silently truncated a 64-bit return value).
