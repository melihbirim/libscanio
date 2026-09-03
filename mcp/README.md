# libscanio-mcp

MCP server exposing libscanio's `scan`/`schema`/`profile`/`count`/`aggregate`/`topk` as agent-callable tools over CSV files, without loading a file into memory (see [../docs/DESIGN.md](../docs/DESIGN.md)).

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
- `topk(path, column, k, where=None, descending=True)` — best K rows by column
- `profile(path)` — schema + row count + best-effort numeric-column aggregates
