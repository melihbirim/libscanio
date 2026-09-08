# Batched scan and validation

Use batches when an import consumes many rows in Python or Node. They
reduce language-boundary calls and decode a whole JSON batch at once.
They do not change the native validation rules or accelerate the existing
`validate()` summary function, which already runs its loop inside Zig.

```python
import libscanio

for batch in libscanio.scan_batches("orders.csv", where="amount > 30"):
    for row in batch:
        consume(row)

rules = {"amount": {"type": "float", "min": 30}}
for batch in libscanio.validate_batches("orders.csv", rules):
    for row, errors in batch:
        consume(row, errors)
```

```javascript
const scanio = require('libscanio');
for await (const batch of scanio.scanBatches('orders.csv', {where: 'amount > 30'})) {
  for (const row of batch) consume(row);
}
for await (const batch of scanio.validateBatches('orders.csv', {
  amount: {type: 'float', min: 30}
})) {
  for (const {number, row, errors} of batch) consume(number, row, errors);
}
```

Python accepts `batch_size` (default 1,024), `target_bytes` (default 1 MiB),
and `as_dict=False` for tuple rows. Node uses `batchSize`, `targetBytes`,
and `asObjects:false` for array rows. The scan APIs accept the same
projection, filter, limit, and negation options as the row iterators.
Batch size must be an integer in 1..65,536; byte target in 1..2,147,483,647.
The default favors modest allocation and GC costs over maximum batch size.

Returned batches own their data and survive the next call or closing the
iterator. Python callers stopping early should close the generator (or
use `contextlib.closing`); breaking a Node `for await` loop closes it.
A malformed row fails the entire current batch. Prior batches remain valid;
rows already consumed inside the failing batch are not returned. Existing
row-at-a-time APIs retain their existing behavior.

The byte target applies to serialized JSON, checked after each complete
row. A single row can exceed it. It is not a hard process-memory ceiling:
scanner buffers, JSON encoding/decoding, runtime objects, allocation
capacity, and batches retained by the caller add memory. Validation
includes every error in each batch, without report-style truncation.

The additive C functions are `scanio_next_batch`,
`scanio_validator_next_batch`, `scanio_batch_json`, and `scanio_batch_free`.
Existing option layouts are unchanged by this feature. C batches own their
JSON independently of the scanner; the pointer has an explicit byte length
and is not NUL-terminated. Close the scanner on error. See
[the header](../include/libscanio.h) for the ownership contract. Rebuild the
native library/addon alongside the updated bindings.

## Reproducing performance measurements

```sh
zig build c-lib node -Doptimize=ReleaseFast
python3 bench/batches.py --rows 200000 --reps 3 --json batch-results.json
```

The harness refuses non-ReleaseFast artifacts, generates a 10-column CSV,
and checks row count, every field's length, invalid-row/error counts, and
an error checksum against an independent Python fixture oracle. Validation
uses four column rules with 10% failing rows. It compares dictionary/object
and tuple/array consumers separately. The native Python validator is a
handwritten implementation of the fixture rules, not a general-purpose
schema validator. Fixtures are ASCII; Unicode and escaping correctness are
covered separately in the binding tests.

Cold timings include fresh-process startup, imports, consumption, and exit.
Warm timings measure a second query after one untimed query in that process.
The OS file cache is not cleared. Peak RSS comes from cold processes and
includes runtime/imports; Python RSS is unavailable on Windows. Timing and
memory differences depend on batch size, row width, invalid-row rate,
runtime, and machine. CI runs a small checksum smoke test with no speed gate.

For current Python bridge measurements, see [CPython API migration](CPYTHON_API_MIGRATION.md).
Generated JSON results remain local or in CI artifacts.
