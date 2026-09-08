# libscanio

Stream CSV, NDJSON, and flat JSON files, filter rows, and validate data using
a native Zig engine through Node's N-API.

## Install

```sh
npm install libscanio@0.1.2
```

Requires Node.js 18 or newer. The package includes native binaries for Linux
x64/ARM64 (glibc 2.28+), Windows x64, and macOS 14+ on Intel and Apple Silicon.
No Zig compiler or third-party npm runtime dependencies are required.
Alpine/musl, Windows ARM64, and browsers are not supported by these binaries.

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

```js
const scanio = require('libscanio');

async function main() {
  for (const path of ['orders.csv', 'orders.ndjson', 'orders.json']) {
    for await (const row of scanio.scan(path, {where: 'amount > 100'})) {
      console.log(row); // { id: '2', amount: '150' }
    }

    console.log(scanio.count(path, 'amount > 100')); // 1

    for await (const batch of scanio.scanBatches(path, {
      batchSize: 1024,
      asObjects: false,
    })) {
      console.log(batch); // arrays of string values
    }
  }
}

main().catch(console.error);
```

## Validation

```js
const scanio = require('libscanio');

for (const path of ['orders.csv', 'orders.ndjson', 'orders.json']) {
  const report = scanio.validate(path, {amount: {min: 0}});
  console.log(report); // both rows are valid in every format
}
```

`validate()` returns a validation report. `validateIter()` and
`validateBatches()` stream rows and errors. `validateToFiles()` writes accepted
and rejected data through the native engine. The Node validation API differs
from Python's fast/full upload API; consult the examples for each binding.

## Memory and execution

Streaming retains parser buffers and the current batch. `scanArray()`, sorting,
and other collectors retain their results. Values are strings; conversion is
explicit. Native work runs synchronously on the calling thread, including
within async iterators, so long operations can block the event loop.

CSV multiline quoted records and nested JSON are not supported.

- [API and examples](https://github.com/melihbirim/libscanio#readme)
- [Input limits](https://github.com/melihbirim/libscanio/blob/main/docs/INPUT_LIMITS.md)
- [Issues](https://github.com/melihbirim/libscanio/issues)

Licensed under Apache-2.0.
