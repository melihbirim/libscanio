# libscanio

A tiny, fast streaming scan engine for structured data.

Scan huge CSV (and later NDJSON) files without loading them into memory.

**open → scan → process, regardless of file size.**

## Status: M1 (scanner only)

Only the file source + CSV parser + row streaming exist right now — no filtering, projection, limit, aggregates, C ABI, or language bindings yet. See [ROADMAP.md](ROADMAP.md) for what's next and why it's sequenced this way.

```zig
const scanio = @import("scanio");

var scanner = try scanio.Scanner.open(allocator, "data.csv");
defer scanner.deinit();

while (try scanner.next()) |row| {
    // row.fields is a zero-copy slice into the mapped file, valid until
    // the next call to next() — copy anything you need to keep.
    const name = row.get(scanner.columnIndex("name").?);
}
```

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
