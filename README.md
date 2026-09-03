# libscanio

Scan and filter structured data without loading it. Your family's RAM-friendly data scanner.

**open → scan → process, regardless of file size.** Measured, not assumed: ~2.2MB peak RSS on a 417MB file, and still ~2.2MB on an 8.5GB one (20x the size, same memory) — see [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

CSV, NDJSON, and JSON arrays behind one `Query` API — filter, project, limit, count, aggregates, top-K. Chunked reads, not mmap: peak memory tracks a fixed buffer size (~2MB), not the file size. See [docs/DESIGN.md](docs/DESIGN.md) for the numbers.

## Status

CSV + NDJSON + JSON arrays, filter/project/limit/count, count/sum/min/max/avg aggregates, O(N log K) top-K, a C ABI, a Python binding. No Node binding, group-by, or Rust binding yet. See [ROADMAP.md](ROADMAP.md).

## Quickstart

```python
import libscanio

# Real query from docs/BENCHMARKS.md, run against the actual 417MB/1M-row
# fixture: 967,553 matches, 0.43s, 2.2MB peak RSS.
for row in libscanio.scan(
    "sample.csv",
    columns=["trip_id", "cab_type"],
    where="cab_type = yellow",
):
    print(row)  # {'trip_id': '649084905', 'cab_type': 'yellow'}
```

```zig
const scanio = @import("scanio");

var q = try scanio.Query.open(allocator, "sample.csv", .{
    .columns = &.{ 0, 24 }, // trip_id, cab_type
    .where = &.{scanio.Predicate.init(24, .eq, "yellow")},
});
defer q.deinit();
while (try q.next()) |row| {
    // row.get(0), row.get(1)
}
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

## Build

Requires [Zig](https://ziglang.org/) 0.15.2.

```bash
zig build test                           # run the test suite
zig build c-lib -Doptimize=ReleaseFast   # -> zig-out/lib/libscanio.{dylib,so,dll}
zig build smoke-test                     # dlopen()s the built library via Python ctypes — the real path
zig build python-test                    # Python binding suite against the real built library
```

## Non-goals

Not a database, not a dataframe, not a SQL engine, no query optimizer, no distributed execution, no mutation APIs (open/scan/close only — no write path). See [ROADMAP.md](ROADMAP.md) for the full list and reasoning.

## Docs

- [docs/DESIGN.md](docs/DESIGN.md) — chunked-read architecture, measured memory/speed tradeoffs, allocator notes
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — measured against `cat`, `grep`, xan, qsv, DuckDB, and a third-party Zig CSV library
- [ROADMAP.md](ROADMAP.md) — milestone history, what's next
- [include/libscanio.h](include/libscanio.h) — C ABI reference

## License

MIT — see [LICENSE.md](LICENSE.md).
