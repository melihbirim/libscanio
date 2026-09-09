# libscanio

Stream CSV, NDJSON, and flat JSON files, filter rows, and validate data with a
Zig engine exposed through a CPython extension.

## Install

```sh
pip install libscanio==0.2.1
```

Prebuilt wheels support CPython 3.10–3.14 on Linux x64/ARM64 (glibc 2.28+),
Windows x64, and macOS 14+ on Intel and Apple Silicon. A matching wheel needs
no Zig installation or C compiler. Alpine/musl, Windows ARM64, and PyPy are
not included in this release.

No third-party Python runtime dependencies.

## Supported file formats

These three files represent the same rows:

**`orders.csv`**

```csv
id,amount
1,50
2,150
```

**`orders.ndjson`** — one flat JSON object per line:

```jsonl
{"id": 1, "amount": 50}
{"id": 2, "amount": 150}
```

**`orders.json`** — an array of flat JSON objects:

```json
[
  {"id": 1, "amount": 50},
  {"id": 2, "amount": 150}
]
```

File-based APIs select the format from the file extension. The same filters,
scans, batches, and validation rules work across all three formats. Scanned
values are strings, including numbers from JSON.

## Scan and filter

```python
import libscanio

for path in ("orders.csv", "orders.ndjson", "orders.json"):
    for row in libscanio.scan(path, where="amount > 100"):
        print(row)  # {"id": "2", "amount": "150"}

    count = libscanio.count(path, where="amount > 100")  # 1

    for batch in libscanio.scan_batches(path, batch_size=1024, as_dict=False):
        for values in batch:
            print(values)  # tuple of strings
```

Streaming keeps memory bounded by parser buffers and the current batch.
`scan_array()`, sorting, and table collection retain results and use memory
proportional to the data they collect. Close streaming generators if you stop early.

## Validate uploads

```python
import libscanio

schema = {"amount": {"min": 0}}

# Default: stop at the first failure and return a boolean.
ok = libscanio.validate(b"amount\n10\n", schema)

# Uploaded JSON and NDJSON bytes require an explicit format.
ok_json = libscanio.validate(b'[{"amount": 10}]', schema, format="json")
ok_ndjson = libscanio.validate(b'{"amount": 10}\n', schema, format="ndjson")

# Paths infer the format from their extension.
for path in ("orders.csv", "orders.ndjson", "orders.json"):
    assert libscanio.validate(path, schema)

# Full: return only failed rows and their errors.
failures = libscanio.validate(b"amount\n-1\n", schema, mode="full")
# [{'values': ['-1'], 'errors': [{'column': 0, 'column_name': 'amount',
#   'rule': 'below_min', 'value': '-1'}]}]
```

Validation accepts bytes or a file path. Bytes default to CSV; pass
`format="ndjson"` or `format="json"` when appropriate. Full validation retains
all failures, so its memory use grows with the number of rejected rows.
`validate_report()` returns summary counters and a bounded error list.
`validate_iter()` and `validate_batches()` expose rows and validation errors.

## Limits and documentation

Fields are strings unless explicitly converted. CSV multiline quoted records
and nested JSON are not supported. Native calls currently hold the Python GIL.

- [API and examples](https://github.com/melihbirim/libscanio#readme)
- [Input limits](https://github.com/melihbirim/libscanio/blob/main/docs/INPUT_LIMITS.md)
- [Validation guide](https://github.com/melihbirim/libscanio/blob/main/docs/UPLOAD_VALIDATION.md)
- [Issues](https://github.com/melihbirim/libscanio/issues)

Source builds require the full repository checkout, Zig 0.15.2, CPython
headers, setuptools, and a C compiler. From the repository root, run
`python -m pip install ./python`.

Licensed under Apache-2.0.
