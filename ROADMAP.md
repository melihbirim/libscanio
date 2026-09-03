# Roadmap

## Core principle

`scan()` is lazy and streaming by default. Never materialize the whole dataset unless explicitly asked (`.collect()` / equivalent).

## Milestones

- [x] **M1 — Scanner**: file source, CSV parser, `next()`, row streaming, constant-memory, Zig API.
- [x] **M2 — Scan operations**: projection, filter, limit, first, count. `count()` with no WHERE clause takes a zero-field-parse fast path (raw newline counting on the mapped bytes) — measured ~10x faster than a full row scan on a 500K-row file. `limit(N)` returns in time proportional to N, not file size (measured near-instant regardless of file size).
- [x] **M3 — C ABI**: `scanio_open` / `scanio_next` / `scanio_count` / `scanio_column_index` / `scanio_close` / `scanio_last_error`, minimal, no Zig internals exposed. Allocator is `std.heap.c_allocator`, not `GeneralPurposeAllocator` — this library gets `dlopen()`'d into a host process, and GPA's PageAllocator faults there (the exact bug csvql shipped once, #149). Verified for real: `zig build smoke-test` loads the built `.dylib`/`.so` via Python `ctypes` — the actual `dlopen()` path, not just Zig's in-process test runner — and runs 200 consecutive open/close cycles to catch allocator faults that only surface after repeated use.
- [x] **M4 — NDJSON**: `src/ndjson.zig`, wired into `Query` via a `Source` tagged union so `scan("data.csv")` and `scan("data.ndjson")` (format inferred from extension, or explicit override) behave identically at every layer — filter, projection, limit, and the newline-only `count()` fast path all work the same for both, since both formats are one-record-per-line. Deliberate scope cut, not hidden: unlike CSV's zero-copy rows, NDJSON parses each line via `std.json.parseFromSlice` (one allocation per row) rather than a hand-rolled zero-copy tokenizer — real, separate engineering, worth doing only if a benchmark shows it matters. Nested objects/arrays are out of scope and fail loudly (`NestedValueNotSupported`) rather than silently stringifying.
- [x] **M5a — Python binding**: `libscanio.scan(path, columns=[...], where="...", limit=...)` — the original target API. WHERE is a simple string (`col OP val [AND col OP val ...]`, no OR — the C ABI only represents a flat AND-list, and nothing has needed more than that yet). Column names are resolved to indices via one throwaway `scanio_open()` before the real, options-bearing open (the C ABI has no header-only entry point; two mmaps of the same file, not two reads, so the OS page cache absorbs it). Building this binding is also what surfaced a real C ABI gap — no way to list header column names — closed by adding `scanio_n_columns`/`scanio_column_name` to M3's surface rather than working around it in Python. Verified via `zig build python-test`, the real dlopen() path via ctypes, not just Zig's in-process tests; caught one real bug this way (two new C ABI functions missing from the ctypes `argtypes`/`restype` declarations caused a segfault — ctypes defaults to a 32-bit `c_int` return type, which mangles a 64-bit pointer/size_t).
- [ ] **M5b — Node binding**: not started.
- [ ] **M6 — Rust**: `cargo add libscanio`, C ABI first, idiomatic wrapper after.
- [x] **M7a — Aggregates + Top-K**: `aggregate()` computes count/sum/min/max/avg over a column in one streaming pass regardless of how many of those five you want — a second pass costs the same as the first. `topK()` adapts csvql's proven `TopKHeap` (`src/fast_sort.zig`, O(N log K) min/max-heap), minus its radix-sort key machinery (not needed for numeric-only top-K at this scope). Real cost named, not hidden: top-K has to retain K rows across the pass, and `Row.fields` point into a reused per-row buffer — so a candidate has to be copied to survive being kept. Mitigated, not eliminated: a row is only copied when `wouldAccept()` says it's an actual heap candidate, not for every row scanned. Measured on 500K rows: `topK(10)` costs about the same as a raw full scan (0.0191s vs 0.0283s) — one pass, not a full sort. Group-by not done (M7b, not started — no consumer has needed it yet).
- [ ] **M8 — Higher-level adapter** (e.g. for an MCP/agent tool): scan/schema/profile/count/aggregate/topk exposed as agent-callable tools. No MCP or AI-specific logic belongs in libscanio itself — that lives in the consumer.

## V1 definition of done

```js
for await (const row of scan("50gb.csv", {
  columns: ["customer_id", "revenue"],
  where: "revenue > 1000",
  limit: 100
})) {
  process(row);
}
```

With: bounded memory, fast first-row latency, correct CSV parsing, Linux/macOS/Windows support, Zig API, C ABI, Node package, Python package. Everything else is secondary.

## Non-goals

Do not build: a database, a dataframe, a SQL parser, a query optimizer, distributed execution, an arbitrary-nested-JSON query engine, dataframe transformations, visualization, an AI agent, a GUI, or any mutation API (no update/delete/in-place edits/transactions — open, scan, close only).

## Benchmarking discipline

Correctness must be verified before any performance claim. Datasets: 10 MB / 100 MB / 1 GB / 10 GB. Scenarios: full scan, single-column projection, multi-column projection, filter at 50%/1% selectivity, `LIMIT 10`, `COUNT`, `SUM`, `TOP 10`. Measure rows/sec, MB/sec, memory, and time-to-first-row — not just throughput.

## Relationship to csvql

csvql should eventually sit on top of libscanio (SQL parser/planner → libscanio → CSV/NDJSON) rather than duplicating scan logic. Extraction happens gradually, one primitive at a time, each step gated by csvql's existing correctness/fuzz/benchmark suite so it's provably zero-behavior-change before the next step starts. csvql remains the SQL product; libscanio is the reusable engine underneath it.
