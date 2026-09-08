# libscanio

Scan and filter structured data without loading it. Your family's RAM-friendly data scanner.

**open → scan → process, regardless of file size.** Measured, not assumed: a filtered scan on a 417MB file takes 0.43s using ~2.2MB of RAM ("RAM" here means [peak RSS](docs/DESIGN.md#what-is-rss) — the most physical memory the process ever actually holds at once, not the file size or a rough guess). Scan a file 20x bigger (8.5GB) and it's still ~2.2MB of RAM, ~9.6s — time grows with the data, memory doesn't. Measured on an Apple M2 Pro (16GB, single-threaded) — see [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for the machine details and every comparison.

CSV, NDJSON, and JSON arrays behind one `Query` API — filter, project, limit, count, aggregates, top-K. Chunked reads, not mmap: peak memory tracks a fixed buffer size (~2MB), not the file size. See [docs/DESIGN.md](docs/DESIGN.md) for the numbers.

## Status

CSV + NDJSON + JSON arrays, filter/project/limit/count, count/sum/min/max/avg aggregates, O(N log K) top-K, single-column ORDER BY, per-column type inference (`describe()`), schema validation for imports (`validate()`/`validate_iter()`), a bounded-memory parallel scan/count/filtered-scan path (`scan_table()` uses 2.3-2.8x less memory than `pyarrow` under N-way concurrent load, the real Python-API-level comparison — see ROADMAP.md), zero-copy Arrow output (`scan_table()`, Python), a C ABI, Python and [Node](node/) bindings, and an [MCP server](mcp/) exposing all of it as agent-callable tools. No group-by, multi-column ORDER BY, or Rust binding yet. See [ROADMAP.md](ROADMAP.md).

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

## CSV, NDJSON, and JSON files

The Python and Node APIs accept `.csv`, `.ndjson`, and `.json` paths. NDJSON
contains one flat object per line; JSON files contain an array of flat objects.
The same scan, filter, count, batching, and validation APIs work across formats.
Scanned field values are strings, including numeric JSON values.

See the [Python examples](python/README.md#supported-file-formats) and
[Node examples](node/README.md#supported-file-formats) for equivalent input
files and runnable examples of all three formats. Python uploaded bytes need
`format="json"` or `format="ndjson"`; CSV is the default for bytes.

## The rows a filter rejects

Every filter has a complement, and for an import that complement is the
half you care about: not "which rows do I want" but "which rows can I not
take". `negate` returns it.

```python
clean    = libscanio.scan_table("orders.csv", where=RULES)                 # -> the loader
rejects  = libscanio.scan_array("orders.csv", where=RULES, negate=True)    # -> a rejects file
how_many = libscanio.count("orders.csv", where=RULES, negate=True)         # -> a gate
```

```js
const rejects = libscanio.scanArray('orders.csv', { where: RULES, negate: true });
const bad     = libscanio.count('orders.csv', RULES, { negate: true });
```

```bash
scanio orders.csv --where "amount >= 0" --not            # the rows that failed
scanio orders.csv --where "amount >= 0" --not --count    # just how many
```

It inverts the **whole** `where` clause — `NOT(a AND b)` — not each
clause individually, which is why it is one flag rather than a boolean
expression language. Two consequences worth knowing:

* **With no `where` it matches nothing**, because the negation of "keep
  everything" is "keep none". `negate` without a filter is almost always
  a mistake, and returning zero rows says so rather than silently
  ignoring the flag.
* **A row too short to hold a predicate's column counts as rejected.** It
  cannot satisfy `amount >= 0`, so it lands with the rejects instead of
  disappearing from both halves.

The two halves always partition the file — every row in exactly one, none
in both, none lost. `zig build diff-test` asserts that across Python,
Node, the CLI and an independent oracle on every run.

Why this matters for imports: the rejects are the *small* side. On a
186MB/3M-row file, pulling the ~1% that failed costs **0.18s**; pulling
the 99% that passed costs 16s. Take the complement and hand the clean
side straight to Arrow or a bulk loader without it ever entering Python.

## Validating an import

`validate()` defaults to fail fast and returns a boolean. Pass uploaded bytes
without writing a temporary file, or supply a file path:

```python
ok = libscanio.validate(uploaded_bytes, schema)  # CSV by default
failed = libscanio.validate(uploaded_bytes, schema, mode="full")
# [{"values": ["42", "bad"], "errors": [{"column": 1,
#   "column_name": "amount", "rule": "bad_type", "value": "bad"}]}]
```

Full mode returns every failed record and every error, without row numbers.
Valid rows never become Python objects. A CPython extension creates failed
rows directly, without intermediate row JSON. Its memory use grows with
rejected data. See [CPython validation benchmarks](docs/CPYTHON_VALIDATION.md). Bytes accept `format="csv"`, `"ndjson"`, or `"json"`; paths infer format
from their extension. File-like objects/chunk streams are not yet accepted.
Input bytes stay owned by Python and are read through a bounded native buffer.
Fast mode stops after the first invalid record and does not inspect the rest;
parser/schema/I/O errors encountered before stopping raise `ScanError`.

**API change:** the previous report-returning Python `validate()` is now
`validate_report()`. Existing Node, CLI and C report APIs are unchanged.

CSV files usually arrive to be *loaded*, not queried, and the question a
loader asks is the opposite of the one a `where` clause answers: not
"which rows do I want" but "which rows can I not take, and why". That
needs a reason, per cell, that you can put in front of a human.

```python
import libscanio

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

```
199,997 of 200,000 rows loadable
  row 41, email: missing_required ('')
  row 118, amount: below_min ('-5')
  row 2207, status: not_in_set ('refunded')
```

Rule keys: `type` (`any`/`integer`/`float`/`boolean`/`datetime`/`string`),
`required`, `min`, `max`, `min_len`, `max_len`, `one_of`. Lengths count
characters, not bytes. A blank cell is *absent*, not badly typed — only
`required` has anything to say about it, so a sparse optional column
doesn't drown the report. A schema key that names no real column, or a
misspelled rule name, raises: a rule that silently does not run is worse
than a call that fails.

For file-to-file imports, `validate_to_files()` (Python) or `validateToFiles()`
(Node) writes accepted CSV and rejected JSONL directly in Zig, in one pass,
returning only totals. Both output paths must be new. See [native import usage
and benchmarks](docs/NATIVE_IMPORT.md).

For bulk row consumption, use `scan_batches()` / `validate_batches()` in
Python or `scanBatches()` / `validateBatches()` in Node. They return owned
batches, defaulting to 1,024 rows, with optional tuple/array output. See
[batch APIs and benchmarks](docs/BATCHING.md).

**Both halves in one pass.** `validate()` gives you the summary;
`validate_iter()` gives you each row *with its failures attached*, which
is what an actual import wants — the good rows go to the target table
and the bad ones to a rejects file without either side being
materialized:

```python
with open("rejects.csv", "w") as rejects:
    for row, errors in libscanio.validate_iter("orders.csv", schema):
        if errors:
            rejects.write(f"{row['id']},{errors[0].rule}\n")
        else:
            load(row)
```

Same thing from Node (`validate` / `validateIter` / `inferSchema`) and
from the CLI, where report mode doubles as a shell gate:

```bash
scanio orders.csv --validate schema.json            # JSON report; exit 1 if any row failed
scanio orders.csv --validate schema.json --valid    # ...or stream just the rows that passed
scanio orders.csv --validate schema.json --invalid  # ...or just the ones that didn't

scanio orders.csv --validate schema.json --max-errors 0 > errors.json   # list every failure, not the first 100
```

Runnable end-to-end examples of exactly this — the summary, the
streaming import, and the inferred draft — are in
[examples/validate_import.py](examples/validate_import.py) and
[examples/validate_import.js](examples/validate_import.js), against
[examples/scores.csv](examples/scores.csv).

Two things worth knowing before writing a rule:

* **`min`/`max` are inclusive.** `{"min": 30}` means >= 30, so a value of
  exactly 30 passes. There is no exclusive form yet; on integer data,
  write `{"min": 31}`.
* **`float` means "any usable number"**, integers included — use it
  unless a decimal point should itself be an error, in which case use
  `integer`. Surrounding whitespace is never data: ` 55 ` is the number
  55 under every numeric rule, and the error still quotes the cell
  exactly as it appears in the file.

Datetime rules now check Gregorian calendar dates (years 1–9999), including
leap years, and numeric timezone offsets (hours 0–23, minutes 0–59).
Impossible dates such as `2024-02-31` fail validation.

Don't have a schema yet? `infer_schema(path)` drafts one from the file's
own shape (via `describe()`'s sampling) for you to edit. It is a starting
point, not a schema to trust: it can only describe the file it read, so a
file that is entirely wrong infers a schema it passes cleanly.

Native validation now reuses float parsing for range checks, compiles large
membership lists, and counts errors beyond a report's sample cap without
constructing discarded error records. See [validation performance and import
benchmarks](docs/VALIDATION_PERFORMANCE.md) for measured gains and limits.

The rules are evaluated in Zig, not in each binding, so Python, Node and
the CLI cannot drift into three different answers about whether a cell is
an integer — `zig build diff-test` asserts all three against an
independent oracle on every run.

**Measured**, on a 126MB / 3M-row / 10-column CSV with four rules across
four columns (same machine and method as
[docs/BENCHMARKS.md](docs/BENCHMARKS.md)):

| | median | throughput | peak RSS |
|---|---|---|---|
| `scanio --validate` (report) | 0.49s | 257 MB/s | **10.1MB** |
| `libscanio.validate_report()` (Python) | 0.48s | 263 MB/s | 10.9MB |
| `libscanio.validate()` (Node) | 0.50s | 253 MB/s | 46.1MB (V8 floor) |
| hand-written Python `csv` loop, same four rules | 4.37s | 29 MB/s | 10.1MB |

For reference on the same file: a plain `--count` is 0.02s (it never
splits a field) and a full scan that splits every field is 0.27s — so the
four rules cost about as much again as the parse they run on, and the
whole thing stays within a rounding error of a scan's memory. The
per-row streaming forms (`validate_iter()` / `validateIter()`) cost
11.4s and 7.8s respectively, because there the per-row crossing into
Python or JavaScript dominates — `scan()` alone over the same file is
9.0s. Use the report when you want the summary; use the streaming form
when you actually need the rows.

What's deliberately absent: uniqueness ("no duplicate ids") and
referential checks. Both need state proportional to the file — a set of
every value seen — which is the one thing this library promises not to
build. They belong in the database doing the import, which already has
the index.

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
