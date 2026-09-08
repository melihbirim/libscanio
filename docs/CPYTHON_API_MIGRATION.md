# CPython API migration

All 17 public Python functions now route native operations through `_native`,
with the Zig core statically linked. There is no public ctypes fallback or
row JSON transport. Query options and validation schemas are encoded once as
JSON input. Python still handles API argument resolution, report classes, and
profile/describe/schema-inference composition.

| APIs | Native path |
|---|---|
| scan, scan_batches | Direct tuple/dictionary construction from borrowed fields |
| scan_array | Parallel columnar collector by default; projected/limited batches otherwise |
| count, aggregate | Native scalar results |
| topk, order_by | Native sorting and direct result construction |
| schema, build_mode | Native metadata |
| validate | Native fast boolean or full failure objects |
| validate_report, validate_iter, validate_batches | Native validation and direct errors |
| validate_to_files | Native file processing and counters |
| profile, describe, infer_schema | Python composition over native scans |

The private `_loader.py` and bundled C ABI library remain for diagnostic and
historical comparison tools. Installed-wheel tests remove the shared library
and exercise every public API in a fresh process. Wheels remain specific to
CPython version, architecture, and platform. The extension holds the GIL;
this migration does not promise concurrent Python-thread scans.

Arrow buffers retain their native allocation after the query, table, or capsule
variable is deleted. Buffers are read-only, with no raw pointer handling in
Python. Streaming batch byte budgets preserve the former encoded-size boundaries
without actually serializing row JSON. Embedded NUL fields are preserved, and
filtered sorts return complete rows, including columns after the predicate.

## Local measurements

200,000 four-column CSV records, five fresh processes per engine/workload,
ReleaseFast, macOS arm64, CPython 3.14.4. Imports are outside timing. Streaming
consumes every field with the same Python length checksum loop; materialization
retains all tuples. Peak RSS includes the interpreter, measured before content
hashing. Ordered output hashes and row counts match across engines. The fixture
includes Unicode, quoted commas, and escaped quotes, but no multiline records
(the existing parser does not support those).

| Workload | CPython bridge | Previous ctypes bridge | Python csv.reader |
|---|---:|---:|---:|
| Streaming | 61.7 ms / 17.8 MiB | 107.7 ms / 19.5 MiB | 111.1 ms / 17.3 MiB |
| Materialize | 32.5 ms / 100.9 MiB | 122.9 ms / 115.1 MiB | 92.2 ms / 76.8 MiB |

Materialization retains the parallel columnar allocation while constructing
Python rows, so its peak memory remains higher than csv.reader. These are local
fixture measurements, not universal or Lambda performance guarantees.

Reproduce with
`SCANIO_BASELINE_PACKAGE=/path/to/old/package/parent python bench/cpython_scan.py`.
Build both package versions in ReleaseFast first. The script writes
`cpython-scan-results.json` in the working directory.

## Verification

The existing 260 Python tests, 286 Zig tests, 177 Node tests, 33 N-API tests,
and 743 cross-client differential checks pass locally. Additional coverage
exercises every public API without the ctypes loader, native handle cleanup,
embedded NULs, empty buffers, and Arrow ownership after garbage collection.
The installed wheel passes after removing its bundled shared library, and
Python tests pass with `PYTHONMALLOC=debug`. A separate before/after comparison
matched 117 cases across CSV, NDJSON, and JSON, including batch boundaries.
The Linux, Windows, and macOS CI jobs also pass, including installed-wheel
tests and cross-client differential checks.
