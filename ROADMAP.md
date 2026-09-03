# Roadmap

## Core principle

`scan()` is lazy and streaming by default. Never materialize the whole dataset unless explicitly asked (`.collect()` / equivalent).

## Milestones

- [x] **M1 — Scanner**: file source, CSV parser, `next()`, row streaming, constant-memory, Zig API.
- [x] **M2 — Scan operations**: projection, filter, limit, first, count. `count()` with no WHERE clause takes a zero-field-parse fast path (raw newline counting on the mapped bytes) — measured ~10x faster than a full row scan on a 500K-row file. `limit(N)` returns in time proportional to N, not file size (measured near-instant regardless of file size).
- [x] **M3 — C ABI**: `scanio_open` / `scanio_next` / `scanio_count` / `scanio_column_index` / `scanio_close` / `scanio_last_error`, minimal, no Zig internals exposed. Allocator is `std.heap.c_allocator`, not `GeneralPurposeAllocator` — this library gets `dlopen()`'d into a host process, and GPA's PageAllocator faults there (the exact bug csvql shipped once, #149). Verified for real: `zig build smoke-test` loads the built `.dylib`/`.so` via Python `ctypes` — the actual `dlopen()` path, not just Zig's in-process test runner — and runs 200 consecutive open/close cycles to catch allocator faults that only surface after repeated use.
- [ ] **M4 — NDJSON**: same scanner abstraction, second format. `scan("data.csv")` and `scan("data.ndjson")` should look nearly identical to callers.
- [ ] **M5 — Node + Python bindings**: `npm install libscanio`, `pip install libscanio`. Largest practical distribution reach, so first.
- [ ] **M6 — Rust**: `cargo add libscanio`, C ABI first, idiomatic wrapper after.
- [ ] **M7 — Aggregates + Top-K**: sum/avg/min/max/group-by where justified, top-k. Reuse proven csvql algorithms rather than reinventing them.
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
