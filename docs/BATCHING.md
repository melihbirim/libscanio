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

## Local measurement snapshot

200,000 rows, three repetitions, batch size 1,024, 1 MiB byte target;
macOS arm64, Python 3.14.4, Node 22.21.0, ReleaseFast. Medians below are
from this implementation. `csv-reader` returns lists, `python-batch-tuple`
returns tuples; both use the same sequence consumer. Dictionary rows use
identical dictionary consumers. Node array/object results have their own
matching consumer. These are consumption benchmarks, not claims about all
API functions or other schemas. Raw data: [BATCH_BENCHMARKS.json](BATCH_BENCHMARKS.json).


Scan + consume all fields
| engine | cold process | warm query | cold peak RSS |
|---|---:|---:|---:|
| csv-dict | 375.8 ms | 342.7 ms | 22.9 MiB |
| python-row | 556.2 ms | 485.9 ms | 24.2 MiB |
| python-batch-dict | 354.8 ms | 296.9 ms | 25.8 MiB |
| csv-reader | 233.7 ms | 178.8 ms | 22.8 MiB |
| python-batch-tuple | 251.8 ms | 186.6 ms | 25.7 MiB |
| node-row | 322.4 ms | 222.8 ms | 60.5 MiB |
| node-batch-object | 274.1 ms | 160.3 ms | 75.4 MiB |
| node-batch-array | 243.3 ms | 128.9 ms | 75.2 MiB |

Validation + consume all fields/errors
| engine | cold process | warm query | cold peak RSS |
|---|---:|---:|---:|
| csv-dict | 430.9 ms | 375.9 ms | 22.8 MiB |
| python-row | 703.5 ms | 624.1 ms | 24.4 MiB |
| python-batch-dict | 475.0 ms | 403.4 ms | 26.6 MiB |
| csv-reader | 268.8 ms | 210.2 ms | 23.0 MiB |
| python-batch-tuple | 370.0 ms | 302.1 ms | 26.7 MiB |
| node-row | 379.7 ms | 278.3 ms | 60.4 MiB |
| node-batch-object | 320.6 ms | 196.5 ms | 91.9 MiB |
| node-batch-array | 277.8 ms | 173.1 ms | 76.0 MiB |

Batching improved warm dictionary/object scan and validation in this run,
with higher peak RSS. Python's built-in reader remained faster for sequence
consumption, and the handwritten Python validation loop remained faster
than our batched validation. JSON transport and runtime object creation
still cost time; batching reduces those costs without eliminating them.
