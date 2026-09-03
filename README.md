# libscanio

Scan and filter structured data without loading it. Your family's RAM-friendly data scanner.

**open → scan → process, regardless of file size.**

CSV, NDJSON, and JSON arrays behind one `Query` API — filter, project, limit, count, aggregates, top-K. Chunked reads, not mmap: peak memory tracks a fixed buffer size (~2MB), not the file size. See [docs/DESIGN.md](docs/DESIGN.md) for the numbers.

## Status

CSV + NDJSON + JSON arrays, filter/project/limit/count, count/sum/min/max/avg aggregates, O(N log K) top-K, a C ABI, a Python binding. No Node binding, group-by, or Rust binding yet. See [ROADMAP.md](ROADMAP.md).

## Quickstart

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

```zig
const scanio = @import("scanio");

var q = try scanio.Query.open(allocator, "10gb.csv", .{
    .columns = &.{ 0, 2 }, // customer_id, revenue
    .where = &.{scanio.Predicate.init(2, .gt, "1000")},
    .limit = 100,
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
