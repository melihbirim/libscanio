"""
libscanio MCP server — exposes scan/schema/profile/count/aggregate/topk/
order_by/describe/infer_schema/validate as agent-callable tools over CSV
files, without ever loading a file into memory (see ../docs/DESIGN.md).

This file is deliberately thin: every tool is a direct pass-through to
the libscanio Python binding (../python/libscanio). No filtering,
formatting, or AI-specific logic lives here or in libscanio itself — per
ROADMAP.md's M8 entry, that's the whole point of keeping this a separate
consumer package instead of baking MCP support into the library.

Run:
    python3 -m venv .venv && .venv/bin/pip install -e .
    .venv/bin/python server.py
"""

import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent.parent / "python"))

import libscanio
from mcp.server.mcpserver import MCPServer

server = MCPServer("libscanio")


@server.tool()
def scan(
    path: str,
    columns: Optional[list[str]] = None,
    where: Optional[str] = None,
    limit: Optional[int] = None,
) -> list[dict[str, str]]:
    """Scan a CSV file and return matching rows. This tool always
    materializes the result list to return it over MCP, so pass `limit`
    for a large file rather than pulling every row into one response.

    Uses scan_array() under the hood, not scan()+list(): when `columns`
    and `limit` are both unset, that dispatches to libscanio's real
    multi-threaded parallel scan engine (measured leaner than pyarrow
    under N-way concurrent load — see ROADMAP.md) instead of draining a
    single-threaded row-at-a-time generator. `columns`/`limit` still
    fall back to the single-threaded path (the parallel engine doesn't
    support projection or a row limit yet).

    where: e.g. "revenue > 1000", "city = Austin AND revenue > 1000", or
    "color IN (yellow, green)". Operators: = != > >= < <= IN. Only AND
    joins clauses — no OR (IN covers "any of these values" without it).
    """
    return libscanio.scan_array(path, columns=columns, where=where, limit=limit, as_dict=True)


@server.tool()
def schema(path: str) -> list[str]:
    """Column names, in header order. Doesn't scan any rows — cheap to
    call before deciding what to filter or aggregate on."""
    return libscanio.schema(path)


@server.tool()
def count(path: str, where: Optional[str] = None) -> int:
    """Row count, optionally filtered. With no `where`, never parses a
    single field — fast regardless of file size."""
    return libscanio.count(path, where=where)


@server.tool()
def aggregate(path: str, column: str, where: Optional[str] = None) -> dict:
    """count/sum/min/max/avg over a numeric column, in one pass."""
    return libscanio.aggregate(path, column, where=where)


@server.tool()
def topk(
    path: str,
    column: str,
    k: int,
    where: Optional[str] = None,
    descending: bool = True,
) -> list[dict]:
    """Top K rows by a numeric column, best-to-worst — one pass, not a
    full sort. Each row includes a "_key" entry with its sort value."""
    return libscanio.topk(path, column, k, where=where, descending=descending)


@server.tool()
def order_by(
    path: str,
    column: str,
    where: Optional[str] = None,
    descending: bool = False,
) -> list[dict[str, str]]:
    """Every matching row, sorted by `column` (numeric if it parses as
    one, string compare otherwise). Materializes the whole matching
    result set before sorting — bounded by the FILTERED row count, not
    the file size, same tradeoff aggregate()/topk() already accept. For
    just the best/worst K rows, prefer topk() — it's one pass, not a
    full sort, and doesn't materialize the whole result set first."""
    return libscanio.order_by(path, column, where=where, descending=descending)


@server.tool()
def describe(path: str, sample_size: int = 1000) -> list[dict]:
    """Column names + an inferred type per column (integer / float /
    boolean / datetime / string / empty), sampled from the first
    `sample_size` rows — bounded cost regardless of file size. A
    heuristic, not a schema: a column consistent for `sample_size` rows
    that changes shape further down won't be caught. Good first call
    before deciding what to filter/aggregate/sort on for a file an agent
    hasn't seen before."""
    return libscanio.describe(path, sample_size=sample_size)


@server.tool()
def profile(path: str) -> dict:
    """Cheap first look at a file an agent hasn't seen before: columns,
    row count, and best-effort aggregates for columns that look numeric.
    Costs one full scan per numeric column found — fine as a one-off,
    not something to call repeatedly on a wide file. For inferred TYPES
    per column (not just numeric-vs-not), prefer describe()."""
    return libscanio.profile(path)


@server.tool()
def infer_schema(path: str, sample_size: int = 1000, required: bool = False) -> dict:
    """Draft a validation schema from what the file already looks like,
    using describe()'s sampled type inference. A starting point to show
    a user and edit — not a schema to trust, since it can only describe
    the file it read: a file that is entirely wrong infers a schema it
    passes cleanly. Pass the (edited) result to validate()."""
    return libscanio.infer_schema(path, sample_size=sample_size, required=required)


@server.tool()
def validate(path: str, schema: dict, max_errors: int = 100) -> dict:
    """Check every row against a schema in one streaming pass and report
    what failed — the question an IMPORT asks, as opposed to the "which
    rows do I want" that scan(where=...) answers.

    schema is keyed by column name:

        {"id":     {"type": "integer", "required": true},
         "amount": {"type": "float", "min": 0},
         "status": {"one_of": ["new", "paid"]},
         "email":  {"required": true, "max_len": 255}}

    type is one of any/integer/float/boolean/datetime/string. Lengths
    count characters, not bytes. A blank cell is ABSENT, not badly
    typed — only `required` has anything to say about it. Every schema
    key must name a real column and every rule name must be spelled
    right; both raise, because a rule that silently does not run is
    worse than a call that fails.

    Returns row counts, per-rule counts, and the first `max_errors`
    individual failures. The counts are complete even when that list is
    capped, so a wholly-broken file still yields an accurate summary
    (and a bounded response) rather than one error per row.
    """
    return libscanio.validate(path, schema, max_errors=max_errors).as_dict()


if __name__ == "__main__":
    server.run()
