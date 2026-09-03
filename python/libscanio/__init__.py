"""
libscanio — scan huge CSV files without loading them into memory.

    import libscanio

    for row in libscanio.scan(
        "10gb.csv",
        columns=["customer_id", "revenue"],
        where="revenue > 1000",
        limit=100,
    ):
        print(row)  # {'customer_id': '4821', 'revenue': '1050'}

Streaming by default — scan() is a generator, nothing is materialized
until you iterate it. Values are always strings; libscanio has no type
inference (same as raw CSV).
"""

import ctypes
import re
from typing import Iterator, Optional, Sequence, Union

from ._loader import CAgg, COptions, CPredicate, load

__all__ = ["scan", "scan_array", "schema", "count", "aggregate", "topk", "profile", "ScanError"]

_OP_MAP = {">=": 3, "<=": 5, "!=": 1, "=": 0, ">": 2, "<": 4}
_OP_IN = 6
_COND_RE = re.compile(r"^(\w+)\s*(>=|<=|!=|>|<|=)\s*(.+)$")
_IN_RE = re.compile(r"^(\w+)\s+IN\s*\((.*)\)$")


class ScanError(RuntimeError):
    """Raised for a failed open, a malformed WHERE condition, or an unknown column."""


def _raise_last_error(lib: ctypes.CDLL, fallback: str) -> None:
    err = lib.scanio_last_error()
    raise ScanError(err.decode(errors="replace") if err else fallback)


def _resolve_column(lib: ctypes.CDLL, ctx: ctypes.c_void_p, name: str) -> int:
    idx = lib.scanio_column_index(ctx, name.encode())
    if idx == ctypes.c_size_t(-1).value:
        raise ScanError(f"unknown column: {name!r}")
    return idx


def _parse_where(
    lib: ctypes.CDLL, ctx: ctypes.c_void_p, where: str
) -> tuple[list[CPredicate], list]:
    """Translate a simple "col OP val [AND col OP val ...]" string into
    typed predicates. Only AND is supported — OR would need the C ABI to
    represent more than a flat, implicitly-ANDed predicate list, which is
    more machinery than libscanio's core has needed to earn yet.

    "col IN (a, b, c)" is also supported as one AND-clause (matches if
    the field equals any of the listed values) — the one case a flat
    AND-list still needed some form of "or" for, common enough (an
    allow-list of categories) to be worth a dedicated op rather than
    requiring N separate scans unioned in Python.

    Returns (predicates, keepalive): `keepalive` holds the ctypes arrays
    backing each IN predicate's `values` pointer. ctypes doesn't keep
    nested pointers alive on its own — the caller must hold `keepalive`
    in scope until after the scanio_open() call that reads it.
    """
    predicates = []
    keepalive = []
    for part in where.split(" AND "):
        part = part.strip()
        m_in = _IN_RE.match(part)
        if m_in:
            col, vals_str = m_in.group(1), m_in.group(2)
            vals = [v.strip() for v in vals_str.split(",") if v.strip()]
            if not vals:
                raise ScanError(f'invalid IN condition (no values): "{part}"')
            arr = (ctypes.c_char_p * len(vals))(*[v.encode() for v in vals])
            keepalive.append(arr)
            predicates.append(
                CPredicate(
                    column=_resolve_column(lib, ctx, col),
                    op=_OP_IN,
                    value=b"",
                    values=ctypes.cast(arr, ctypes.POINTER(ctypes.c_char_p)),
                    n_values=len(vals),
                )
            )
            continue
        m = _COND_RE.match(part)
        if not m:
            raise ScanError(f'invalid WHERE condition: "{part}"')
        col, op, val = m.group(1), m.group(2), m.group(3).strip()
        predicates.append(
            CPredicate(
                column=_resolve_column(lib, ctx, col),
                op=_OP_MAP[op],
                value=val.encode(),
            )
        )
    return predicates, keepalive


def scan(
    path: str,
    columns: Optional[Sequence[str]] = None,
    where: Optional[str] = None,
    limit: Optional[int] = None,
) -> Iterator[dict[str, str]]:
    """Scan a CSV file, yielding one dict per matching row.

    Args:
        path: Path to the CSV file.
        columns: Column names to return, in order. Default: all columns.
        where: Simple filter, e.g. "revenue > 1000" or
               "city = Austin AND revenue > 1000" or
               "color IN (yellow, green)". Operators: = != > >= < <= IN.
               Only AND joins clauses — no OR (IN covers the common
               "any of these values" case without it).
        limit: Maximum rows to return. Default: no limit.

    Raises:
        ScanError: file not found, malformed WHERE, or unknown column name.
    """
    lib = load()
    ctx, names, _keepalive = _open_full(lib, path, columns, where, limit)
    try:
        fields = ctypes.POINTER(ctypes.c_char_p)()
        n = ctypes.c_size_t()
        while True:
            rc = lib.scanio_next(ctx, ctypes.byref(fields), ctypes.byref(n))
            if rc == 0:
                return
            if rc < 0:
                _raise_last_error(lib, "scan failed")
            yield {names[i]: fields[i].decode() for i in range(n.value)}
    finally:
        lib.scanio_close(ctx)


def _open_full(
    lib: ctypes.CDLL,
    path: str,
    columns: Optional[Sequence[str]],
    where: Optional[str],
    limit: Optional[int],
) -> tuple[ctypes.c_void_p, list[str], list]:
    """Shared open logic for scan() and scan_array(): resolve column
    names + WHERE to indices/predicates (via a throwaway probe open,
    same reasoning as _open_filtered()), then open for real with the
    resolved options. Returns (ctx, column names in output order,
    keepalive) — `keepalive` must stay in scope until the caller is done
    with `ctx` (it backs any IN predicates' values arrays)."""
    probe_ctx = lib.scanio_open(path.encode(), None)
    if not probe_ctx:
        _raise_last_error(lib, f"failed to open {path!r}")
    try:
        col_indices = [_resolve_column(lib, probe_ctx, c) for c in columns] if columns else None
        predicates, keepalive = _parse_where(lib, probe_ctx, where) if where else (None, [])
    finally:
        lib.scanio_close(probe_ctx)

    columns_arr = (ctypes.c_size_t * len(col_indices))(*col_indices) if col_indices else None
    where_arr = (CPredicate * len(predicates))(*predicates) if predicates else None
    opts = COptions(
        columns=columns_arr,
        n_columns=len(col_indices) if col_indices else 0,
        where=where_arr,
        n_where=len(predicates) if predicates else 0,
        limit=limit if limit is not None else -1,
    )

    ctx = lib.scanio_open(path.encode(), ctypes.byref(opts))
    if not ctx:
        _raise_last_error(lib, f"failed to open {path!r}")

    names = columns if columns else [
        lib.scanio_column_name(ctx, i).decode() for i in range(lib.scanio_n_columns(ctx))
    ]
    return ctx, names, keepalive


def scan_array(
    path: str,
    columns: Optional[Sequence[str]] = None,
    where: Optional[str] = None,
    limit: Optional[int] = None,
    as_dict: bool = False,
) -> list:
    """Like scan(), but for when you actually want every matching row
    back as a Python list/array right now, not streamed. Collects the
    WHOLE result in Zig first and hands it to Python as one bulk copy,
    instead of one small ctypes call per field per row — that per-call
    crossing cost, not the scan itself, is what dominates scan()'s speed
    once you materialize its output with list(...) anyway. Measured on a
    417MB/1M-row file, 2 projected columns, ~967K matches: list(scan())
    took ~4.8s: scan_array() ~0.5s.

    Returns a list of tuples (default) or dicts (as_dict=True) — tuples
    are cheaper (no per-row dict construction) and are what you want if
    you're about to hand this to something column-oriented (numpy,
    pandas, a DB insert) rather than accessing fields by name.

    Not streaming, not memory-bounded the way scan() is — this
    materializes every matching row in both Zig and Python at once. Use
    scan() and iterate without collecting a list if the whole point is
    staying within bounded memory on a huge file.
    """
    lib = load()
    ctx, names, _keepalive = _open_full(lib, path, columns, where, limit)
    try:
        cc = lib.scanio_collect(ctx)
        if not cc:
            _raise_last_error(lib, "collect failed")
        try:
            n_rows = lib.scanio_collect_n_rows(cc)
            n_cols = lib.scanio_collect_n_cols(cc)
            if n_rows == 0:
                return []
            length = ctypes.c_size_t()
            ptr = lib.scanio_collect_data(cc, ctypes.byref(length))
            data = ctypes.string_at(ptr, length.value)  # one bulk copy, not N small ones
            # One decode() over the whole buffer, not one per field — a
            # single bulk decode plus str.split() is far cheaper than
            # calling bytes.decode() ~n_rows*n_cols times. Measured on a
            # 417MB/1M-row file, 2 projected columns, ~967K matches: per-
            # field decode cost alone was the difference between this
            # path's Python-side reshape taking ~0.9s and ~0.06s.
            text = data.decode()
            parts = text.split("\x00")[:-1]  # trailing empty string from the last NUL
            # zip(*[iter(parts)] * n_cols) chunks the flat list into
            # n_cols-tuples — measured ~3x faster than index-slicing
            # (parts[i*n_cols:(i+1)*n_cols] per row) for this row count.
            rows = zip(*[iter(parts)] * n_cols)
            if as_dict:
                return [dict(zip(names, row)) for row in rows]
            return list(rows)
        finally:
            lib.scanio_collect_close(cc)
    finally:
        lib.scanio_close(ctx)


def _open_filtered(lib: ctypes.CDLL, path: str, where: Optional[str]) -> ctypes.c_void_p:
    """Open with WHERE resolved to predicates — the shared setup schema(),
    count(), aggregate(), and topk() all need before doing their own
    thing. Same two-open pattern scan() uses: one throwaway open to
    resolve column names, one real open with the resolved options."""
    if not where:
        ctx = lib.scanio_open(path.encode(), None)
        if not ctx:
            _raise_last_error(lib, f"failed to open {path!r}")
        return ctx

    probe_ctx = lib.scanio_open(path.encode(), None)
    if not probe_ctx:
        _raise_last_error(lib, f"failed to open {path!r}")
    try:
        predicates, _keepalive = _parse_where(lib, probe_ctx, where)
    finally:
        lib.scanio_close(probe_ctx)

    where_arr = (CPredicate * len(predicates))(*predicates)
    opts = COptions(columns=None, n_columns=0, where=where_arr, n_where=len(predicates), limit=-1)
    ctx = lib.scanio_open(path.encode(), ctypes.byref(opts))
    if not ctx:
        _raise_last_error(lib, f"failed to open {path!r}")
    return ctx


def schema(path: str) -> list[str]:
    """Column names, in header order. Doesn't scan any rows."""
    lib = load()
    ctx = lib.scanio_open(path.encode(), None)
    if not ctx:
        _raise_last_error(lib, f"failed to open {path!r}")
    try:
        return [lib.scanio_column_name(ctx, i).decode() for i in range(lib.scanio_n_columns(ctx))]
    finally:
        lib.scanio_close(ctx)


def count(path: str, where: Optional[str] = None) -> int:
    """Row count. With no `where`, never parses a single field."""
    lib = load()
    ctx = _open_filtered(lib, path, where)
    try:
        n = lib.scanio_count(ctx)
        if n < 0:
            _raise_last_error(lib, "count failed")
        return n
    finally:
        lib.scanio_close(ctx)


def aggregate(path: str, column: str, where: Optional[str] = None) -> dict[str, Optional[float]]:
    """count/sum/min/max/avg over `column`, in one pass. Non-numeric or
    missing values are skipped, not errors. min/max/avg are None if no
    numeric value was ever seen (count == 0)."""
    lib = load()
    ctx = _open_filtered(lib, path, where)
    try:
        col_idx = _resolve_column(lib, ctx, column)
        out = CAgg()
        if lib.scanio_aggregate(ctx, col_idx, ctypes.byref(out)) != 0:
            _raise_last_error(lib, "aggregate failed")
        has_values = bool(out.has_values)
        return {
            "count": out.count,
            "sum": out.sum,
            "min": out.min if has_values else None,
            "max": out.max if has_values else None,
            "avg": out.avg if has_values else None,
        }
    finally:
        lib.scanio_close(ctx)


def topk(
    path: str,
    column: str,
    k: int,
    where: Optional[str] = None,
    descending: bool = True,
) -> list[dict[str, str]]:
    """Top K rows by `column` (parsed as a number), best-to-worst — one
    pass, O(N log K), not a full sort. Each returned row is a normal
    scan()-shaped dict plus a "_key" entry with that row's numeric value
    for the sorted column."""
    lib = load()
    ctx = _open_filtered(lib, path, where)
    try:
        col_idx = _resolve_column(lib, ctx, column)
        names = [lib.scanio_column_name(ctx, i).decode() for i in range(lib.scanio_n_columns(ctx))]
        tctx = lib.scanio_topk(ctx, col_idx, k, 1 if descending else 0)
        if not tctx:
            _raise_last_error(lib, "topk failed")
        try:
            results = []
            fields = ctypes.POINTER(ctypes.c_char_p)()
            n = ctypes.c_size_t()
            key = ctypes.c_double()
            while True:
                rc = lib.scanio_topk_next(tctx, ctypes.byref(fields), ctypes.byref(n), ctypes.byref(key))
                if rc == 0:
                    return results
                if rc < 0:
                    _raise_last_error(lib, "topk failed")
                row = {names[i]: fields[i].decode() for i in range(n.value)}
                row["_key"] = key.value
                results.append(row)
        finally:
            lib.scanio_topk_close(tctx)
    finally:
        lib.scanio_close(ctx)


def profile(path: str, sample_limit: int = 1) -> dict:
    """A cheap overview for an agent deciding how to query a file it
    hasn't seen before: column names, total row count, and best-effort
    aggregates for columns that look numeric.

    "Looks numeric" is a heuristic, not a schema: it checks whether the
    first non-empty value in each column (from the first `sample_limit`
    rows) parses as a float. A column that's numeric in its first rows
    but has stray text further down still gets aggregated — aggregate()
    already skips non-numeric values rather than failing on them — but a
    column that's genuinely mixed from row one won't be flagged here.
    Each numeric column costs its own full scan (aggregate() is one pass
    per column, not one pass total) — fine for an occasional profile
    call, not something to run in a hot loop over a wide file.
    """
    cols = schema(path)
    total_rows = count(path)

    sample_rows = list(scan(path, limit=sample_limit))
    numeric_cols = []
    for col in cols:
        for row in sample_rows:
            val = row.get(col, "")
            if val == "":
                continue
            try:
                float(val)
                numeric_cols.append(col)
            except ValueError:
                pass
            break

    return {
        "columns": cols,
        "row_count": total_rows,
        "numeric_columns": {col: aggregate(path, col) for col in numeric_cols},
    }
