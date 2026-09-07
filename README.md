# libscanio

Scan and filter structured data without loading it. Your family's RAM-friendly data scanner.

**open → scan → process, regardless of file size.** Measured, not assumed: a filtered scan on a 417MB file takes 0.43s using ~2.2MB of RAM ("RAM" here means [peak RSS](docs/DESIGN.md#what-is-rss) — the most physical memory the process ever actually holds at once, not the file size or a rough guess). Scan a file 20x bigger (8.5GB) and it's still ~2.2MB of RAM, ~9.6s — time grows with the data, memory doesn't. Measured on an Apple M2 Pro (16GB, single-threaded) — see [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for the machine details and every comparison.

CSV, NDJSON, and JSON arrays behind one `Query` API — filter, project, limit, count, aggregates, top-K. Chunked reads, not mmap: peak memory tracks a fixed buffer size (~2MB), not the file size. See [docs/DESIGN.md](docs/DESIGN.md) for the numbers.

## Status

CSV + NDJSON + JSON arrays, filter/project/limit/count, count/sum/min/max/avg aggregates, O(N log K) top-K, single-column ORDER BY, per-column type inference (`describe()`), a bounded-memory parallel scan/count/filtered-scan path (`scan_table()` uses 2.3-2.8x less memory than `pyarrow` under N-way concurrent load, the real Python-API-level comparison — see ROADMAP.md), zero-copy Arrow output (`scan_table()`, Python), a C ABI, Python and [Node](node/) bindings, and an [MCP server](mcp/) exposing all of it as agent-callable tools. No group-by, multi-column ORDER BY, or Rust binding yet. See [ROADMAP.md](ROADMAP.md).

**CSV quoting: RFC 4180, minus multi-line records.** A field whose first
byte is `"` is a quoted field: the delimiter inside it is data
(`1,"Smith, John",London` is three fields), and `""` is one literal `"`.
A quote anywhere other than the first byte is ordinary data, so
`he said "hi"` comes back verbatim. Writing CSV (`scanio --format csv`)
re-quotes only the fields that need it, so a scan round-trips.

The one thing that is **not** supported is a quoted field containing a
newline. The reader is line-oriented and the parallel path splits the
file into byte ranges at newlines, so such a record would be torn in half
before any splitter saw it. Rather than hand back two half-rows, it is
`UnterminatedQuote` — a loud failure on a file this reader cannot
represent. If your data has embedded newlines, normalise it first (or use
[csvql](https://github.com/melihbirim/csvql), which parses SQL and CSV
properly).

Rows with more or fewer fields than the header are handled and tested —
extras get a positional `colN` key, missing ones are absent.

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

# Want every matching row back as a Python list right now, not streamed?
# scan_array() does the whole filtered scan in one call and hands the
# result to Python in bulk instead of one row/field at a time — the same
# query above as list(scan(...)) took 4.8s; scan_array() takes ~0.6s.
# Not memory-bounded like scan() — it materializes everything at once.
rows = libscanio.scan_array("sample.csv", columns=["trip_id", "cab_type"], where="cab_type = yellow")
```

```js
const libscanio = require('libscanio');

for await (const row of libscanio.scan("sample.csv", {
    columns: ["trip_id", "cab_type"],
    where: "cab_type = yellow",
})) {
    console.log(row); // { trip_id: '649084905', cab_type: 'yellow' }
}

// scanArray() is the same bulk-materialize tradeoff as Python's scan_array().
const rows = libscanio.scanArray("sample.csv", { columns: ["trip_id", "cab_type"], where: "cab_type = yellow" });
```

```bash
# CLI — no interpreter, no imports, no FFI. Streams results as it finds
# them, so memory is flat whatever matches.
zig build cli -Doptimize=ReleaseFast     # -> zig-out/bin/scanio

scanio sample.csv --where "cab_type = yellow" --columns trip_id,cab_type
scanio sample.csv --where "revenue > 1000 AND cab_type = yellow" --count
scanio events.ndjson --where "status IN (open, pending)" --format ndjson
```

On a 1MB file the whole process — start, scan, print, exit — takes
**1.9ms**, against 40ms through the Python binding and 199ms for the
equivalent polars call, because below ~100MB the query is not what costs;
starting the runtime is. It stays ahead at 166MB (107ms vs polars' 271ms)
at 10MB of peak RSS.

Deliberately not a query language: one file, flags, no joins, no GROUP BY,
no SQL. If you want SQL over CSV, use [csvql](https://github.com/melihbirim/csvql)
— a query parser is exactly the startup cost this binary exists to avoid.

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
zig build node-test                      # Node binding suite — N-API addon, zero runtime dependencies, no npm install needed
zig build cli -Doptimize=ReleaseFast     # -> zig-out/bin/scanio
zig build diff-test                      # every client on the same queries, cross-checked against an independent oracle
```

## Non-goals

Not a database, not a dataframe, not a SQL engine, no query optimizer, no distributed execution, no mutation APIs (open/scan/close only — no write path). See [ROADMAP.md](ROADMAP.md) for the full list and reasoning.

## Docs

- [docs/DESIGN.md](docs/DESIGN.md) — chunked-read architecture, measured memory/speed tradeoffs, allocator notes
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — measured against `cat`, `grep`, xan, qsv, and a third-party Zig CSV library
- [ROADMAP.md](ROADMAP.md) — milestone history, what's next
- [include/libscanio.h](include/libscanio.h) — C ABI reference

## License

Apache-2.0 — see [LICENSE.md](LICENSE.md).
