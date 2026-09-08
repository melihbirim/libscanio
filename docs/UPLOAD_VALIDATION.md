# Upload validation

Python `validate(source, schema)` now returns a boolean and defaults to fast
mode. It stops after the first invalid record. `mode="full"` scans the entire
input and returns every failed record, with all its errors and no row numbers.
Valid records are never serialized or converted into Python objects.

```python
import libscanio

schema = {"amount": {"type": "float", "min": 0}}
valid = libscanio.validate(uploaded_bytes, schema)
failures = libscanio.validate(uploaded_bytes, schema, mode="full")
# [{"values": ["-1"], "errors": [{"column": 0,
#   "column_name": "amount", "rule": "below_min", "value": "-1"}]}]
```

Bytes default to CSV. Use `format="ndjson"` or `format="json"` for JSON.
String/PathLike paths also work, inferring format from the extension.
No temporary or output files are required for bytes. Python retains ownership
of the input; native scanners borrow it for the synchronous call and copy
chunks into reusable read buffers. Arbitrary file-like objects and incremental
upload streams are not supported by this API yet. In Lambda this avoids
mandatory `/tmp` staging for bytes already received, but does not avoid storing
those uploaded bytes in memory or undo download time already spent.

Full output uses positional string values, preserving duplicate CSV column
names and extra fields on ragged rows. Errors identify the zero-based column
and its name; structural errors have a null column. JSON uses the same flat
record parser and first-record column inference as the existing scanner.

Full mode has no failure cap. Memory grows with rejected data; during conversion
native JSON and Python results can coexist. Fast mode retains no error list;
parser memory depends on buffering, record size and schema. Encountered I/O,
UTF-8, schema and parser errors raise `ScanError`. A malformed tail after an
early validation failure is deliberately not examined in fast mode.

## Migration

The previous Python report-returning `validate(path, schema, max_errors=...)`
is now `validate_report(...)`. Repository callers have been migrated.
Node, CLI and existing C report functions retain their previous contracts.
The additive C API is `scanio_validate_outcome` / `scanio_outcome_free`.

## Performance evidence

```sh
zig build c-lib -Doptimize=ReleaseFast
PYTHONPATH=python python3 bench/upload_validation.py --rows 200000 --reps 5
```

200,000 in-memory CSV records, five repetitions, macOS arm64 / Python 3.14.4.
The Python baseline uses csv.reader and a handwritten float/minimum check.
Both implementations produce identical decisions and rejected values/errors
for these fixtures. Generation and warmup are excluded. Full timings include
constructing the returned Python objects. This is a warm local benchmark,
not an AWS Lambda measurement or a comparison of every supported rule.

| Scenario | Mode | Native median | Python median |
|---|---|---:|---:|
| All valid | fast | 7.46 ms | 40.58 ms |
| All valid | full | 7.58 ms | 40.52 ms |
| First invalid | fast | 0.011 ms | 0.005 ms |
| Only first invalid | full | 7.54 ms | 41.15 ms |
| 1% invalid | full | 9.33 ms | 43.27 ms |
| All invalid | full | 215.44 ms | 121.71 ms |

Call/setup overhead dominates an immediate failure. Full mode with widespread
failures is slower than handwritten Python because every rejected value and
error crosses the JSON boundary. The speedup applies to complete scans with
few failures, not universally. Raw samples are in
[UPLOAD_VALIDATION_BENCHMARKS.json](UPLOAD_VALIDATION_BENCHMARKS.json).
