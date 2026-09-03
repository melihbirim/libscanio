# libscanio (Node)

Node binding for [libscanio](../README.md) — scan CSV files without loading them into memory. Same shape as the Python binding, via [koffi](https://koffi.dev) (dynamic FFI, no native compilation step).

## Setup

```bash
zig build c-lib -Doptimize=ReleaseFast   # from the repo root — builds the .dylib/.so/.dll this depends on
cd node
npm install
npm test
```

## API

```js
const libscanio = require('libscanio');

for await (const row of libscanio.scan('10gb.csv', {
  columns: ['customer_id', 'revenue'],
  where: 'revenue > 1000',
  limit: 100,
})) {
  console.log(row); // { customer_id: '4821', revenue: '1050' }
}
```

- `scan(path, {columns, where, limit})` — async generator, streamed, bounded memory
- `scanArray(path, {columns, where, limit, asObjects})` — bulk-materializes matches fast, not memory-bounded (see its doc comment in `lib/index.js`)
- `schema(path)` — column names
- `count(path, where?)` — row count
- `aggregate(path, column, where?)` — count/sum/min/max/avg
- `topk(path, column, k, where?, descending?)` — best K rows by column, every column returned per row
- `profile(path)` — schema + row count + best-effort numeric-column aggregates

WHERE syntax: `"col OP val [AND col OP val ...]"` or `"col IN (a, b, c)"`. Operators: `= != > >= < <= IN`. Only `AND` joins clauses.
