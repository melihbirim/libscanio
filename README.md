# libscanio

Scan and filter structured data without loading it. Your family's RAM-friendly data scanner.

A tiny, fast streaming scan engine for structured data.

Scan huge CSV, NDJSON, and JSON array files without loading them into memory. Chunked reads, not mmap, across all three formats — peak RSS tracks chunk size (~2MB by default), not file size. See [ROADMAP.md](ROADMAP.md)'s M1 and M4 entries for the measurements.

**open → scan → process, regardless of file size.**

## Status: M7a (CSV + NDJSON, filter/project/limit/count, aggregates, top-K, C ABI, Python)

CSV, NDJSON, and JSON arrays behind one `Query` API (format sniffed from content for `.json`, from extension otherwise), filter/projection/limit/first/count, count/sum/min/max/avg aggregates in one pass, O(N log K) top-K, a stable C ABI (`include/libscanio.h`), and a Python binding. No Node binding, group-by, or Rust binding yet. See [ROADMAP.md](ROADMAP.md) for what's next and why it's sequenced this way.

**Allocator matters, measured, not assumed**: pass `std.heap.c_allocator` to `Query.open()`, not `GeneralPurposeAllocator` — on a 500K-row NDJSON file this was the difference between 42K and 2.78M rows/sec (66x), independent of the parser used. The C ABI already does this for you; a Zig caller building directly on `Query` needs to choose it explicitly. NDJSON now runs 4.7M rows/sec cold (single-process) or a steady ~6.0M rows/sec warm (repeated calls in the same process) after also reusing the per-row fields array instead of reallocating it — see `ndjson.zig`'s doc comment and [ROADMAP.md](ROADMAP.md)'s M4 entry for the full story, including a real segfault the reuse work surfaced and how it was fixed.

```zig
// Aggregates and top-K compose with WHERE, same as everything else.
var q = try scanio.Query.open(allocator, "sales.csv", .{ .where = &.{scanio.Predicate.init(1, .eq, "Austin")} });
defer q.deinit();
const stats = try scanio.aggregate(&q, 2); // sum/count/min/max/avg of column 2

var q2 = try scanio.Query.open(allocator, "sales.csv", .{});
defer q2.deinit();
var top10 = try scanio.topK(allocator, &q2, 2, 10, true); // top 10 by column 2, descending
defer top10.deinit();
for (top10.getSorted()) |entry| {
    // entry.row.get(0), entry.key
}
```

```python
import libscanio

for row in libscanio.scan(
    "10gb.csv",
    columns=["customer_id", "revenue"],
    where="revenue > 1000",
    limit=100,
):
    print(row)  # {'customer_id': '4821', 'revenue': '1050'}
```

```bash
cd python && pip install -e .
zig build python-test   # runs the Python binding suite against the real built library
```

```c
#include <libscanio.h>

scanio_t *s = scanio_open("data.csv", NULL);
const char **fields;
size_t n;
while (scanio_next(s, &fields, &n) == 1) {
    // fields[0..n)
}
scanio_close(s);
```

```bash
zig build c-lib -Doptimize=ReleaseFast   # -> zig-out/lib/libscanio.{dylib,so,dll}
zig build smoke-test                     # dlopen()s the built library via Python ctypes — the real path
```

```zig
const scanio = @import("scanio");

// Raw scan — every row, every column.
var scanner = try scanio.Scanner.open(allocator, "data.csv");
defer scanner.deinit();
while (try scanner.next()) |row| {
    // row.fields is a zero-copy slice into the mapped file, valid until
    // the next call to next() — copy anything you need to keep.
}

// Filtered, projected, limited — the Python/Node target shape:
//   scan("10gb.csv", columns=["customer_id", "revenue"], where="revenue > 1000", limit=100)
var q = try scanio.Query.open(allocator, "10gb.csv", .{
    .columns = &.{ 0, 2 }, // customer_id, revenue
    .where = &.{scanio.Predicate.init(2, .gt, "1000")},
    .limit = 100,
});
defer q.deinit();
while (try q.next()) |row| {
    // ...
}

// count() with no filter never parses a single field — it counts
// newlines directly on the mapped bytes.
var counter = try scanio.Query.open(allocator, "10gb.csv", .{});
defer counter.deinit();
const total_rows = try counter.count();
```

Measured on a 500K-row CSV (`zig build bench -Doptimize=ReleaseFast -- file.csv`): `count()` with no filter is ~10x faster than a full row scan, and `limit(10)` returns in ~0.0001s regardless of file size — both are the direct result of *not doing* the work a naive implementation would, not a faster way of doing it.

## Design

- **Chunked reads, not mmap** — CSV `Scanner` reads a fixed-size buffer (256KB by default) at a time, reused for the whole scan. Peak memory tracks the chunk size, not the file size: measured 2.2MB peak RSS scanning a 417MB/1M-row file, versus 426MB for an earlier mmap-based version of the same scanner (mmap has to fault in, and keeps resident, every page it touches — peak RSS == file size by construction for a full scan). `cat` on the same file holds ~1.4MB; chunked `Scanner` is in that regime now, not file-size territory. Cost: ~30% slower than the mmap version (read() syscalls vs lazy page faults) — a real tradeoff, made explicitly for the memory win. The chunk size was swept, not guessed (64KB/256KB/1MB/4MB/16MB, 10 runs each) — see [ROADMAP.md](ROADMAP.md)'s M1 entry for the full table; time is flat from 64KB to 4MB while RSS scales with chunk size, so smaller wins with no speed cost until syscall overhead would start to bite. It's configurable per-call, not fixed: `Scanner.openWithOptions(allocator, path, .{ .chunk_size = N })` or `Query.open(allocator, path, .{ .csv_chunk_size = N })`.
- **Zero-copy rows** — almost every field is a slice into the current chunk, never a fresh allocation. Only a line that straddles a chunk boundary gets copied into a small reused scratch buffer instead of the chunk directly — same "valid until the next `next()` call" contract either way.
- **One reusable scratch buffer** for field offsets, grown (not reallocated) only when a row has more fields than any row seen so far — not a per-row cost.

## Non-goals

Not a database, not a dataframe, not a SQL engine, no query optimizer, no distributed execution, no mutation APIs (open/scan/close only — no write path). See [ROADMAP.md](ROADMAP.md) for the full list and the reasoning behind each one.

## Build

Requires [Zig](https://ziglang.org/) 0.15.2.

```bash
zig build test              # run the test suite
zig build scan -- file.csv  # scan a file, report rows/sec
```

## License

MIT — see [LICENSE.md](LICENSE.md).
