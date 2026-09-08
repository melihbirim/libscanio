# Native validation to files

Use `validate_to_files()` when the destination is accepted CSV plus rejected
JSONL. It reads the input once, evaluates the schema, and writes both outputs
inside Zig. Python receives only the row/error totals. This avoids batch JSON
transport, Python row-object construction, and Python per-row writing.

```python
import libscanio

stats = libscanio.validate_to_files(
    "orders.csv",
    {"amount": {"type": "float", "min": 30}},
    "accepted.csv",
    "rejected.jsonl",
)
print(stats)  # rows_total, rows_valid, rows_invalid, errors_total
```

```javascript
const scanio = require('libscanio');
const stats = scanio.validateToFiles(
  'orders.csv', {amount: {type: 'float', min: 30}},
  'accepted.csv', 'rejected.jsonl'
);
// rowsTotal, rowsValid, rowsInvalid, errorsTotal
```

Node's call is synchronous, like `validate()`. Use `validate_batches()` /
`validateBatches()` when application code needs to transform rows, call a
service, or write to a database. The native file API does not execute such
application-specific work.

## Output contract

- Input is UTF-8 CSV, NDJSON, or a JSON array, with the existing scanner's
  format and validation semantics. Malformed input fails the call; validation
  failures instead route the parsed row to the rejects file.
- Accepted output is CSV with a header and CRLF record separators. Fields
  are quoted as needed; values are parsed field strings, not original raw
  source lines. A single empty field is explicitly quoted.
- Rejected output has LF-delimited compact JSON objects shaped as
  `{"values":["..."],"errors":[...]}`. Positional values preserve duplicate
  header names and ragged extra fields. Column names/order come from the
  accepted file's header, which is written even when every row is rejected.
- Every rejected row retains every validation failure. Error objects contain
  the same row number, column, column name, rule, and value as streaming
  validation. There is no report-style error cap.
- Both output paths must be new. Existing files, including aliases of the
  input, are refused without truncation. On a reported failure, files created
  by this call are closed and removed on a best-effort basis. Outputs can be
  visible while being written; publication of the pair is not transactional.
- Success flushes application buffers and closes the files. It does not
  fsync them. Scanner storage, the current row's errors, and two 64 KiB
  output buffers replace retained batches; individual record size is not
  capped by this API.

The additive C function is `scanio_validate_to_files()`; it returns an
explicit four-counter stats structure. Existing C option layouts are unchanged.
Rebuild the native library/addon with updated bindings.

## One open for other validation APIs

Reports and iterators in Python, Node, and the CLI now use
`Validator.openJson()`: open the scanner, compile the schema against its
header, and continue from that scanner's buffered position. The previous
probe/reopen pattern duplicated initial reads, not full scans. CLI validation
also bypasses its unrelated scan setup. The schema is owned by the validator
and stays valid when the validator is moved.

## Reproduce the complete import comparison

```sh
zig build c-lib node -Doptimize=ReleaseFast
python3 bench/import_validation.py --rows 200000 --reps 5 --json import-results.json
```

All four implementations write the same accepted CSV and compact rejection
JSONL bytes, verified with SHA-256. Every input field and rejection reason
is included. Output files are removed before timing each repetition; source
creation, output verification, and cleanup are outside the timer. Open,
validation, conversion, writes, flushes, and closes are inside it. No fsync is
requested. The four-column ASCII fixture has four rules and 10% rejected rows;
this is a file import comparison, not a general application or database test.
Engine order rotates, one warmup is excluded, and the OS cache is not cleared.
CI runs this path on a small fixture and gates output equality, not speed.


## Historical local results (before the CPython migration)

macOS arm64, Python 3.14.4, Zig 0.15.2 ReleaseFast. Five measured repetitions
at 200,000 rows and three at 1,000,000 rows, after a warmup:

| Complete import | 200,000 rows | 1,000,000 rows |
|---|---:|---:|
| Handwritten Python CSV validation | 496 ms | 2,485 ms |
| `validate_iter()` + Python writing | 692 ms | 3,430 ms |
| `validate_batches()` + Python writing | 503 ms | 2,525 ms |
| `validate_to_files()` native routing | **36 ms** | **182 ms** |

The native file path was about 14× faster than handwritten Python on this
fixture at both sizes. Its main advantage is eliminating the language/data
conversion round trip and Python output loop, not the small initial-read
saving. Output hashes were identical across engines: 180,000 accepted /
20,000 rejected rows in the small run, and 900,000 / 100,000 in the large run.
This benefit applies when the native file outputs satisfy the actual import
requirement; it does not accelerate arbitrary Python per-row business logic.

The reproduction command writes samples and output hashes to `import-results.json`.
Generated results are kept locally or as CI artifacts.
Numbers from the older import benchmark are not directly interchangeable:
all engines now emit the same compact positional rejection JSONL format.
