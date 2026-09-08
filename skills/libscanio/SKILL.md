---
name: libscanio
description: Query large CSV/NDJSON/JSON files without loading them into memory or piping through pandas/jq. Use whenever a task involves reading, filtering, counting, aggregating, or sorting a CSV/NDJSON file, especially a large one, or validating rows against a schema. Prefer this over `cat`/`head`+manual parsing, `python -c "import pandas..."`, or `jq` on delimited data.
---

# libscanio

`scanio` is a CLI (and Python/Node/C library) that scans CSV, NDJSON, and
JSON-array files with bounded memory and predicate pushdown — it never
materializes a file to answer `count`/`aggregate`/`where`-filtered queries.
On a repo task, reach for it instead of loading a file into pandas or piping
through `jq`/`awk` when the question is "how many rows match X" or "give me
these columns where Y" rather than "transform this file."

## FIRST: check what's available

```bash
scanio --help                      # CLI on PATH (brew/release binary)
python3 -c "import libscanio"      # pip install libscanio
node -e "require('libscanio')"     # npm install libscanio
```

If none are installed and the task only needs one query, `pip install
libscanio` or `brew install melihbirim/libscanio/libscanio` is faster than
writing a manual parser. Values are always strings — libscanio does no type
inference (same as raw CSV); parse numerically after reading.

## CLI

```
scanio <file> [options]

  --where <clause>    "col OP val [AND col OP val ...]" or "col IN (a, b)"
                       OP is one of = != > >= < <=
  --columns <a,b,c>   only these columns, in this order
  --limit <n>         stop after n matching rows
  --count              print just the number of matching rows
  --not                invert --where: emit the rows it REJECTS
  --format <fmt>       csv (default) or ndjson
```

Format (CSV / NDJSON / JSON array) is inferred from the file extension.
Output streams as it's found — memory stays flat regardless of match count.

```bash
scanio orders.csv --where "amount > 1000 AND status = paid" --columns id,amount
scanio events.ndjson --count --where "level = error"
```

Import validation (schema keyed by column name, `type` one of
any/integer/float/boolean/datetime/string):

```bash
scanio data.csv --validate schema.json          # JSON report, exit 1 on any failure
scanio data.csv --validate schema.json --invalid # stream only the rows that failed
```

## Python

```python
import libscanio

libscanio.schema(path)                       # column names, no scan
libscanio.count(path, where=None)             # no WHERE = never parses a field
libscanio.aggregate(path, column, where=None) # {count, sum, min, max, avg} in one pass
libscanio.topk(path, column, k, descending=True)   # one pass, O(N log K)
libscanio.order_by(path, column, where=None)
libscanio.describe(path, sample_size=1000)    # inferred type per column
libscanio.profile(path)                        # cheap first look at an unseen file
for row in libscanio.scan(path, columns=None, where=None, limit=None):
    ...                                        # streaming, dict rows
libscanio.scan_array(path, where=None, as_dict=False)  # materializes, arrays by default
libscanio.validate_report(path, schema, max_errors=100)
```

## Node

```js
const libscanio = require('libscanio');

libscanio.schema(path);
libscanio.count(path, where);
libscanio.aggregate(path, column, where);
libscanio.topk(path, column, k, where, descending);
libscanio.orderBy(path, column, where, descending);
for await (const row of libscanio.scan(path, { columns, where, limit })) { }
libscanio.scanArray(path, { where, asObjects: true });
```

## When NOT to use this

- Transforming/rewriting a file (reshaping columns, joins across files) —
  libscanio is read-only, one file at a time.
- A file already small enough that `cat`/normal parsing is instant and the
  task isn't going to run repeatedly.
