# libscanio

Stream CSV, NDJSON, and flat JSON files, filter rows, and validate data using
a native Zig engine through Node's N-API.

## Install

```sh
npm install libscanio@0.1.0
```

Requires Node.js 18 or newer. The package includes native binaries for Linux
x64/ARM64 (glibc 2.28+), Windows x64, and macOS 14+ on Intel and Apple Silicon.
No Zig compiler or third-party npm runtime dependencies are required.
Alpine/musl, Windows ARM64, and browsers are not supported by these binaries.

## Scan and filter

Given `orders.csv` with `id` and `amount` columns:

```js
const scanio = require('libscanio');

async function main() {
  for await (const row of scanio.scan('orders.csv', {where: 'amount > 100'})) {
    console.log(row); // object with string values
  }

  console.log(scanio.count('orders.csv', 'amount > 100'));

  for await (const batch of scanio.scanBatches('orders.csv', {
    batchSize: 1024,
    asObjects: false,
  })) {
    console.log(batch); // arrays of string values
  }
}

main().catch(console.error);
```

## Validation

```js
const scanio = require('libscanio');

const report = scanio.validate('orders.csv', {amount: {min: 0}});
console.log(report);
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
