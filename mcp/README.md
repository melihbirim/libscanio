# libscanio-mcp

MCP server exposing libscanio's `scan`/`schema`/`profile`/`count`/`aggregate`/`group_by`/`topk`/`order_by`/`describe`/`infer_schema`/`validate` as agent-callable tools over CSV files, without loading a file into memory (see [../docs/DESIGN.md](../docs/DESIGN.md)).

This package is a thin wrapper, on purpose — no filtering/formatting/AI-specific logic lives here or in libscanio itself. See [../ROADMAP.md](../ROADMAP.md)'s M8 entry.

## Setup

```bash
zig build c-lib -Doptimize=ReleaseFast   # from the repo root — builds the .dylib/.so this depends on
cd mcp
python3 -m venv .venv
.venv/bin/pip install -e .
.venv/bin/python server.py
```

## Tools

- `scan(path, columns=None, where=None, limit=None)` — matching rows
- `schema(path)` — column names
- `count(path, where=None)` — row count
- `aggregate(path, column, where=None)` — count/sum/min/max/avg
- `group_by(path, group_column, agg_column, where=None)` — count/sum/min/max/avg per group
- `topk(path, column, k, where=None, descending=True)` — best K rows by column
- `order_by(path, column, where=None, descending=False)` — every matching row, sorted by column
- `describe(path, sample_size=1000)` — column names + inferred type per column (integer/float/boolean/datetime/string/empty)
- `infer_schema(path, sample_size=1000, required=False)` — draft a validation schema from the file's own shape, to show a user and edit
- `validate(path, schema, max_errors=100)` — check every row against a schema and report what failed: row counts, per-rule counts, and the first `max_errors` individual failures
- `profile(path)` — schema + row count + best-effort numeric-column aggregates
