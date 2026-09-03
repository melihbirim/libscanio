# libscanio

A tiny, fast streaming scan engine for structured data.

Scan huge CSV (and later NDJSON) files without loading them into memory.

**open → scan → process, regardless of file size.**

## Status: M5a (scan + filter + project + limit + C ABI + Python)

File source, CSV parser, filter, projection, limit, first, count, a stable C ABI (`include/libscanio.h`), and a Python binding. No aggregates or Node binding yet. See [ROADMAP.md](ROADMAP.md) for what's next and why it's sequenced this way.

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

- **Memory-mapped on POSIX** (Linux/macOS), read-once-into-a-buffer on Windows (no native mmap fallback yet). Either way, the whole file is read from disk exactly once.
- **Zero-copy rows** — every field is a slice into that one buffer, never a fresh allocation per row.
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
