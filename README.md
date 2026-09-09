# libscanio

Scan and filter structured data without loading it. Your family's RAM-friendly data scanner.

## Problem

Filtering a big CSV/NDJSON file usually means loading it fully into
memory first (pandas, a JS array, a naive parser). Memory use then tracks
file size — a 10GB file costs 10GB+ of RAM, or it crashes.

## Solution

libscanio reads in a fixed-size buffer and never holds more than that,
regardless of file size. Filter, count, aggregate, or stream rows from
CSV, NDJSON, or JSON arrays — from Python, Node, C, Zig, or the `scanio`
CLI, one `Query` API underneath all of them. See
[docs/DESIGN.md](docs/DESIGN.md) for how the buffer bound works.

## Performance

Peak RSS (physical memory actually used, not the file size) tracks the
fixed-size read buffer, not the file — a 1MB file and an 11GB file both
cost about the same handful of megabytes of RAM to scan. Time scales with
the data instead: bigger file, more time, never more memory. That's an
architectural property, verifiable directly from `docs/DESIGN.md`'s
chunked-read design, not a benchmark claim against any other engine.

Against other engines, on real NYC taxi data (417MB, 51 columns, a
low-selectivity early-column WHERE — full method and every number:
[docs/BENCHMARKS.md](docs/BENCHMARKS.md)):

- **0.016-0.023s, 30-54MB peak RSS** (Python/Node) vs polars (0.122s,
  538MB), duckdb (0.306s, 238MB), pyarrow.dataset (0.785s, 159MB).
- At 8.5GB (20x bigger): **1.46-1.75s, 30-54MB** — still beats duckdb
  (3.08s), pyarrow (16.0s), and polars (16.6s, 2.4GB).

Not every shape wins: polars' native column scan is faster on a bare
2-column projection. Full breakdown, including that honest loss, is in
the doc above.

## Status

CSV + NDJSON + JSON arrays; filter/project/limit/count; count/sum/min/max/avg
aggregates; O(N log K) top-K; single-column ORDER BY; per-column type
inference (`describe()`); schema validation for imports (`validate()`); a
C ABI; Python and [Node](node/) bindings; an [MCP server](mcp/). No
group-by, multi-column ORDER BY, or Rust binding yet. See
[ROADMAP.md](ROADMAP.md).

CSV quoting follows RFC 4180 except quoted fields cannot contain a newline
(the reader is line-oriented, by design — see [DESIGN.md](docs/DESIGN.md)).
Rows with more or fewer fields than the header are handled: extras get a
positional `colN` key, missing ones are absent.

## Quickstart

```python
import libscanio

for row in libscanio.scan("sample.csv", columns=["trip_id", "cab_type"], where="cab_type = yellow"):
    print(row)  # {'trip_id': '649084905', 'cab_type': 'yellow'}

# scan_array() does the whole filtered scan in one call instead of one row
# at a time — faster, but materializes the whole result (not memory-bounded).
rows = libscanio.scan_array("sample.csv", columns=["trip_id", "cab_type"], where="cab_type = yellow")
```

```js
const libscanio = require('libscanio');

for await (const row of libscanio.scan("sample.csv", { columns: ["trip_id", "cab_type"], where: "cab_type = yellow" })) {
    console.log(row); // { trip_id: '649084905', cab_type: 'yellow' }
}

const rows = libscanio.scanArray("sample.csv", { columns: ["trip_id", "cab_type"], where: "cab_type = yellow" });
```

```bash
# CLI — no interpreter, no imports, no FFI. Streams results as found.
scanio sample.csv --where "cab_type = yellow" --columns trip_id,cab_type
scanio sample.csv --where "revenue > 1000 AND cab_type = yellow" --count
scanio events.ndjson --where "status IN (open, pending)" --format ndjson
```

Deliberately not a query language: one file, flags, no joins, no GROUP BY,
no SQL. For SQL over CSV, see [csvql](https://github.com/melihbirim/csvql).

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

## CSV, NDJSON, and JSON files

Python and Node accept `.csv`, `.ndjson`, and `.json` paths — one flat
object per NDJSON line, or an array of flat objects for JSON. Same scan,
filter, count, and validation APIs across all three. Values are always
strings, including numeric JSON values. See
[Python](python/README.md#supported-file-formats) and
[Node](node/README.md#supported-file-formats) examples.

## The rows a filter rejects

`negate=True`/`negate: true`/`--not` returns the complement of a filter:
the rows it rejects, not the ones it accepts. Built for imports — the
rejects are usually the small side, so pulling just them is cheaper than
pulling everything that passed. It inverts the whole `where` clause. With
no `where` it matches nothing: keeping everything negated is keeping
nothing.

```python
rejects = libscanio.scan_array("orders.csv", where=RULES, negate=True)
```

```bash
scanio orders.csv --where "amount >= 0" --not --count   # how many failed
```

## Validating an import

A loader needs a reason per bad row, not just a filter. `validate_report()`
checks every row against a schema in one pass:

```python
schema = {
    "id":     {"type": "integer", "required": True},
    "email":  {"required": True, "max_len": 255},
    "amount": {"type": "float", "min": 0},
    "status": {"one_of": ["new", "paid", "shipped"]},
}
report = libscanio.validate_report("orders.csv", schema)
print(f"{report.rows_valid:,} of {report.rows_total:,} rows loadable")
for e in report.errors:
    print(f"  row {e.row}, {e.column_name}: {e.rule} ({e.value!r})")
```

Rule keys: `type` (`any`/`integer`/`float`/`boolean`/`datetime`/`string`),
`required`, `min`, `max`, `min_len`, `max_len`, `one_of`. No schema yet?
`infer_schema(path)` drafts one from the file itself. Edit it.

Same thing from the CLI, where report mode doubles as a shell gate:

```bash
scanio orders.csv --validate schema.json            # JSON report; exit 1 if any row failed
scanio orders.csv --validate schema.json --invalid  # ...or stream just the rows that failed
```

For streaming an import row-by-row with failures attached, use
`validate_iter()` (Python) / `validateIter()` (Node). For file-to-file
imports in one native pass, see [docs/NATIVE_IMPORT.md](docs/NATIVE_IMPORT.md).
Full rule reference, benchmarks, and edge cases:
[docs/VALIDATION_PERFORMANCE.md](docs/VALIDATION_PERFORMANCE.md).

## Build

Requires [Zig](https://ziglang.org/) 0.15.2.

```bash
zig build test                           # run the test suite
zig build cli -Doptimize=ReleaseFast     # -> zig-out/bin/scanio
zig build c-lib -Doptimize=ReleaseFast   # -> zig-out/lib/libscanio.{dylib,so,dll}
zig build python-test                    # Python binding suite
zig build node-test                      # Node binding suite
zig build diff-test                      # every client, same queries, cross-checked
```

## Non-goals

Not a database, not a dataframe, not a SQL engine, no query optimizer, no
distributed execution, no mutation APIs (open/scan/close only — no write
path). See [ROADMAP.md](ROADMAP.md) for the full list and reasoning.

## Using this with Claude Code

[skills/libscanio/SKILL.md](skills/libscanio/SKILL.md) is a Claude Code
[skill](https://docs.claude.com/en/docs/claude-code/skills) — Claude Code
auto-discovers it and loads it only when a task matches its description.

```bash
mkdir -p .claude/skills/libscanio
curl -fsSL https://raw.githubusercontent.com/melihbirim/libscanio/main/skills/libscanio/SKILL.md \
  -o .claude/skills/libscanio/SKILL.md
```

Use `~/.claude/skills/libscanio/` instead to make it available in every
project. No CLAUDE.md edit needed — skills are discovered by directory.

## Docs

- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — every speed/memory comparison, method and numbers
- [docs/DESIGN.md](docs/DESIGN.md) — chunked-read architecture, allocator notes
- [ROADMAP.md](ROADMAP.md) — milestone history, what's next
- [include/libscanio.h](include/libscanio.h) — C ABI reference

## License

Apache-2.0 — see [LICENSE.md](LICENSE.md).
