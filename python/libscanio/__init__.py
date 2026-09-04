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
until you iterate it. Values returned by scan()/scan_array() are always
strings; libscanio does no type conversion there (same as raw CSV).
describe() is the exception — a diagnostic, sampled TYPE GUESS per
column, not a schema scan() itself relies on or enforces.
"""

import ctypes
import datetime
import re
from typing import Iterator, Optional, Sequence, Union

from ._loader import CAgg, COptions, CPredicate, load

__all__ = ["scan", "scan_array", "scan_table", "schema", "count", "aggregate", "topk", "order_by", "profile", "describe", "ScanError"]

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
    # keepalive isn't otherwise referenced below, but MUST stay bound in
    # this generator's frame for as long as ctx is in use — see
    # _open_full()'s doc comment for why (a real use-after-free bug, not
    # a hypothetical one, lived here until this was fixed).
    ctx, names, keepalive = _open_full(lib, path, columns, where, limit)  # noqa: F841
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
    resolved options.

    Returns (ctx, column names in output order, keepalive). `keepalive`
    MUST stay referenced by the caller for as long as `ctx` is used, not
    just through this function — real bug found (not hypothetical) when
    it didn't: Zig's Predicate.value is a slice VIEW into the raw bytes
    behind CPredicate.value, not a copy. Once this function returns, if
    nothing still references `where_arr`/`opts`/`predicates`/the encoded
    value bytes, CPython's refcounting frees them immediately (not
    "eventually" — the instant refcount hits zero) — and the next
    scanio_next() call on `ctx` then reads freed memory. Manifested as
    scan() silently returning far fewer rows than actually matched (1
    instead of ~1000+) once Python bytecode ran between scanio_open()
    and the following scanio_next() calls, which never happened for
    count()/aggregate()/topk() (one C call does their whole WHERE-drain,
    so nothing got a chance to free the backing memory mid-scan) — this
    is why the bug went unnoticed until an actual multi-row scan() call
    was checked against its true expected count, not just "does this
    call run without erroring."
    """
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
    # Only safe to bound when `columns` was explicitly given — None means
    # the caller wants every column back, so every field must still be
    # split regardless of what WHERE touches. When columns IS given, the
    # bound is the highest index either the projection or WHERE reads —
    # real, measured win (up to 3.6x) since trailing fields past it are
    # never scanned at all, not just discarded. See ROADMAP.md.
    max_column = -1
    if col_indices is not None:
        needed = list(col_indices) + ([p.column for p in predicates] if predicates else [])
        max_column = max(needed)
    opts = COptions(
        columns=columns_arr,
        n_columns=len(col_indices) if col_indices else 0,
        where=where_arr,
        n_where=len(predicates) if predicates else 0,
        limit=limit if limit is not None else -1,
        max_column=max_column,
    )
    keepalive = keepalive + [predicates, where_arr, columns_arr, opts]

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

    Multi-threaded by default (parallelScan, the same engine
    parallelCountRowsWhere() already uses) whenever `columns` and
    `limit` are both unset — the common case, and the one an N-way
    concurrency experiment showed this Python binding was previously NOT
    using at all (see ROADMAP.md): the single-threaded scanio_collect()
    path this replaced measured 1.3GB/6.2s for 1.24M matching rows on a
    real 10-column fixture; the multi-threaded path this uses now
    measured 15-895MB/0.05-0.47s across N=1-32 CONCURRENT processes on
    the same real data — genuinely faster and leaner than duckdb on the
    identical task, not just "less bad." `columns`/`limit` fall back to
    the single-threaded path (parallelScan doesn't support projection or
    a row limit yet — real, current scope gap, not silently wrong).
    """
    lib = load()
    if columns is not None or limit is not None:
        return _scan_array_single_threaded(lib, path, columns, where, limit, as_dict)
    return _scan_array_parallel(lib, path, where, as_dict)


def _scan_array_single_threaded(
    lib: ctypes.CDLL,
    path: str,
    columns: Optional[Sequence[str]],
    where: Optional[str],
    limit: Optional[int],
    as_dict: bool,
) -> list:
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


def _scan_array_parallel(lib: ctypes.CDLL, path: str, where: Optional[str], as_dict: bool) -> list:
    names = schema(path)

    probe_ctx = lib.scanio_open(path.encode(), None)
    if not probe_ctx:
        _raise_last_error(lib, f"failed to open {path!r}")
    try:
        predicates, keepalive = _parse_where(lib, probe_ctx, where) if where else (None, [])  # noqa: F841
    finally:
        lib.scanio_close(probe_ctx)

    where_arr = (CPredicate * len(predicates))(*predicates) if predicates else None
    n_where = len(predicates) if predicates else 0

    cc = lib.scanio_parallel_collect_columnar(path.encode(), b",", where_arr, n_where, 0)
    if not cc:
        _raise_last_error(lib, "parallel scan failed")
    try:
        n_rows = lib.scanio_collect_columnar_n_rows(cc)
        n_cols = lib.scanio_collect_columnar_n_cols(cc)
        if n_rows == 0:
            return []

        columns_data = []
        for col_idx in range(n_cols):
            data_len = ctypes.c_size_t()
            data_ptr = lib.scanio_collect_columnar_data(cc, col_idx, ctypes.byref(data_len))
            data = ctypes.string_at(data_ptr, data_len.value) if data_ptr else b""
            off_len = ctypes.c_size_t()
            offsets_ptr = lib.scanio_collect_columnar_offsets(cc, col_idx, ctypes.byref(off_len))
            offsets = offsets_ptr[: off_len.value]
            columns_data.append([data[offsets[i] : offsets[i + 1]].decode() for i in range(n_rows)])

        rows = list(zip(*columns_data))
        if as_dict:
            return [dict(zip(names, row)) for row in rows]
        return rows
    finally:
        lib.scanio_collect_columnar_close(cc)


class _ColumnarHandle:
    """Keeps a scanio_parallel_collect_columnar() result alive for as
    long as any pyarrow Array/Table built from it still references the
    underlying C buffers — passed as `base=` to every pa.foreign_buffer()
    call below. pyarrow's own refcounting (not an explicit close() call
    here) decides when it's actually safe to free the C-side memory:
    once the LAST Arrow object referencing any of this handle's buffers
    is garbage-collected, THIS object's refcount drops to zero, __del__
    runs, and only then does scanio_collect_columnar_close() actually
    free anything. Get this wrong (close too early) and pyarrow holds a
    dangling pointer into freed memory — the same use-after-free class
    of bug _open_full()'s own doc comment already warns about for
    ctypes-backed predicate memory, here for the Zig-owned result buffer
    instead.
    """

    def __init__(self, lib: ctypes.CDLL, cc: ctypes.c_void_p):
        self._lib = lib
        self._cc = cc

    def __del__(self) -> None:
        if self._cc:
            self._lib.scanio_collect_columnar_close(self._cc)
            self._cc = None


def scan_table(path: str, where: Optional[str] = None):
    """Every matching row as a `pyarrow.Table` — zero-copy from the same
    Zig-side columnar (data, offsets) buffers scan_array() uses, but
    with NO per-cell Python object construction at all (scan_array()
    still builds one Python str per field; this builds only lightweight
    Arrow array wrappers over the SAME memory scanio_parallel_collect_
    columnar() already allocated). Multi-threaded (parallelScan), same
    as scan_array()'s default path.

    Requires pyarrow (`pip install pyarrow`) — raises ImportError with a
    clear message if it isn't installed, rather than silently falling
    back to something slower and calling that success.

    No `columns`/`limit`/`as_dict` — this is the maximally-cheap path
    for "give me everything as a real columnar structure I can hand to
    pandas/numpy/downstream Arrow tooling," not a drop-in scan_array()
    replacement. Use scan_array() for row-shaped dicts/tuples, or
    projection/limit.
    """
    try:
        import pyarrow as pa
    except ImportError as e:
        raise ImportError("scan_table() requires pyarrow: pip install pyarrow") from e

    lib = load()
    names = schema(path)

    probe_ctx = lib.scanio_open(path.encode(), None)
    if not probe_ctx:
        _raise_last_error(lib, f"failed to open {path!r}")
    try:
        predicates, keepalive = _parse_where(lib, probe_ctx, where) if where else (None, [])  # noqa: F841
    finally:
        lib.scanio_close(probe_ctx)

    where_arr = (CPredicate * len(predicates))(*predicates) if predicates else None
    n_where = len(predicates) if predicates else 0

    cc = lib.scanio_parallel_collect_columnar(path.encode(), b",", where_arr, n_where, 0)
    if not cc:
        _raise_last_error(lib, "parallel scan failed")

    n_rows = lib.scanio_collect_columnar_n_rows(cc)
    n_cols = lib.scanio_collect_columnar_n_cols(cc)
    if n_rows == 0:
        lib.scanio_collect_columnar_close(cc)
        return pa.table({name: pa.array([], type=pa.string()) for name in names})

    # Ownership of `cc` transfers to this handle from here on — pyarrow's
    # refcounting on the buffers below (via `base=handle`) determines
    # when scanio_collect_columnar_close() actually runs, not this
    # function returning.
    handle = _ColumnarHandle(lib, cc)

    arrays = []
    for col_idx in range(n_cols):
        data_len = ctypes.c_size_t()
        data_ptr = lib.scanio_collect_columnar_data(cc, col_idx, ctypes.byref(data_len))
        off_len = ctypes.c_size_t()
        offsets_ptr = lib.scanio_collect_columnar_offsets(cc, col_idx, ctypes.byref(off_len))

        data_addr = ctypes.cast(data_ptr, ctypes.c_void_p).value if data_ptr else None
        data_buf = pa.foreign_buffer(data_addr, data_len.value, base=handle) if data_addr else pa.py_buffer(b"")
        offsets_addr = ctypes.cast(offsets_ptr, ctypes.c_void_p).value
        offsets_buf = pa.foreign_buffer(offsets_addr, off_len.value * 4, base=handle)

        arr = pa.Array.from_buffers(pa.string(), n_rows, [None, offsets_buf, data_buf])
        arrays.append(arr)

    return pa.table(arrays, names=names)


def _open_filtered(
    lib: ctypes.CDLL, path: str, where: Optional[str], extra_column: Optional[int] = None
) -> tuple[ctypes.c_void_p, list]:
    """Open with WHERE resolved to predicates — the shared setup schema(),
    count(), aggregate(), and topk() all need before doing their own
    thing. Same two-open pattern scan() uses: one throwaway open to
    resolve column names, one real open with the resolved options.

    `extra_column`: aggregate()/topk() read exactly one column that
    isn't expressed via WHERE — passing its index here lets the bound
    below include it, so their scan is bounded even without a WHERE
    clause. count() passes None (it either uses the newline-only fast
    path with no WHERE, which never splits a field regardless of any
    bound, or needs exactly the WHERE columns and nothing else).

    Returns (ctx, keepalive) — see _open_full()'s doc comment for why
    `keepalive` must stay referenced by the caller until `ctx` is closed,
    not just through this function. Same bug class, same fix."""
    if not where and extra_column is None:
        ctx = lib.scanio_open(path.encode(), None)
        if not ctx:
            _raise_last_error(lib, f"failed to open {path!r}")
        return ctx, []

    predicates: list = []
    keepalive: list = []
    if where:
        probe_ctx = lib.scanio_open(path.encode(), None)
        if not probe_ctx:
            _raise_last_error(lib, f"failed to open {path!r}")
        try:
            predicates, keepalive = _parse_where(lib, probe_ctx, where)
        finally:
            lib.scanio_close(probe_ctx)

    where_arr = (CPredicate * len(predicates))(*predicates) if predicates else None
    # Always safe to bound here — unlike scan()/scan_array(), nothing
    # calling _open_filtered() ever needs "every column" back; count()
    # discards rows entirely and aggregate()/topk() read exactly one.
    needed = [p.column for p in predicates] + ([extra_column] if extra_column is not None else [])
    max_column = max(needed) if needed else -1
    opts = COptions(
        columns=None, n_columns=0, where=where_arr, n_where=len(predicates), limit=-1, max_column=max_column
    )
    keepalive = keepalive + [predicates, where_arr, opts]
    ctx = lib.scanio_open(path.encode(), ctypes.byref(opts))
    if not ctx:
        _raise_last_error(lib, f"failed to open {path!r}")
    return ctx, keepalive


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
    ctx, _keepalive = _open_filtered(lib, path, where)
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
    # Resolve the target column before opening for real so _open_filtered
    # can bound the scan to it (plus any WHERE columns) — real, measured
    # speedup, see _open_filtered()'s doc comment.
    probe = lib.scanio_open(path.encode(), None)
    if not probe:
        _raise_last_error(lib, f"failed to open {path!r}")
    try:
        col_idx = _resolve_column(lib, probe, column)
    finally:
        lib.scanio_close(probe)

    ctx, _keepalive = _open_filtered(lib, path, where, extra_column=col_idx)
    try:
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
    ctx, _keepalive = _open_filtered(lib, path, where)
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


def order_by(
    path: str,
    column: str,
    where: Optional[str] = None,
    descending: bool = False,
) -> list[dict[str, str]]:
    """Every matching row, sorted by `column` (numeric if the column
    parses as one, string compare otherwise — same rule scan()'s WHERE
    clause already uses). Materializes the whole matching result set
    before sorting, same memory tradeoff aggregate()/topk() already
    accept: bounded by the FILTERED row count, not the file size."""
    lib = load()
    ctx, _keepalive = _open_filtered(lib, path, where)
    try:
        col_idx = _resolve_column(lib, ctx, column)
        names = [lib.scanio_column_name(ctx, i).decode() for i in range(lib.scanio_n_columns(ctx))]
        octx = lib.scanio_order_by(ctx, col_idx, 1 if descending else 0)
        if not octx:
            _raise_last_error(lib, "order_by failed")
        try:
            results = []
            fields = ctypes.POINTER(ctypes.c_char_p)()
            n = ctypes.c_size_t()
            while True:
                rc = lib.scanio_order_by_next(octx, ctypes.byref(fields), ctypes.byref(n))
                if rc == 0:
                    return results
                if rc < 0:
                    _raise_last_error(lib, "order_by failed")
                results.append({names[i]: fields[i].decode() for i in range(n.value)})
        finally:
            lib.scanio_order_by_close(octx)
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


# Conservative on purpose: unambiguous ISO-ish formats only. No MM/DD-vs-
# DD/MM guessing (real ambiguity, no way to resolve it from the string
# alone) and no locale-dependent month names. A column that doesn't match
# any of these just falls through to "string" — a wrong "string"
# classification is a missed nicety; a wrong "datetime" classification is
# actively misleading, so the bar here favors false negatives.
_DATETIME_FORMATS = (
    "%Y-%m-%dT%H:%M:%SZ",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d",
)


def _infer_column_type(values: list[str]) -> str:
    """`values`: non-empty sampled strings for one column. Checked most-
    specific first (boolean, then integer, then float, then datetime),
    ALL must match for that classification to apply — a bounded sample
    is already forgiving of rare exceptions further down the file;
    requiring every SAMPLED value to agree keeps false positives low."""
    if not values:
        return "empty"

    if all(v.lower() in ("true", "false") for v in values):
        return "boolean"

    def is_int(v: str) -> bool:
        try:
            int(v)
            return True
        except ValueError:
            return False

    if all(is_int(v) for v in values):
        return "integer"

    def is_float(v: str) -> bool:
        try:
            float(v)
            return True
        except ValueError:
            return False

    if all(is_float(v) for v in values):
        return "float"

    def is_datetime(v: str) -> bool:
        for fmt in _DATETIME_FORMATS:
            try:
                datetime.datetime.strptime(v, fmt)
                return True
            except ValueError:
                continue
        return False

    if all(is_datetime(v) for v in values):
        return "datetime"

    return "string"


def describe(path: str, sample_size: int = 1000) -> list[dict]:
    """Column names + an inferred type per column (integer / float /
    boolean / datetime / string / empty), sampled from the first
    `sample_size` rows — bounded cost regardless of file size, same
    tradeoff profile()'s own numeric-column detection accepts.

    This is a heuristic, not a schema: a column that's consistent for
    `sample_size` rows and then changes shape further down won't be
    caught (same limitation profile() already has for its numeric-column
    detection). Datetime detection is deliberately conservative — a
    small set of unambiguous ISO-ish formats, no MM/DD-vs-DD/MM guessing
    — a wrong "string" classification is a missed nicety, a wrong
    "datetime" one is actively misleading.
    """
    cols = schema(path)
    sample_rows = list(scan(path, limit=sample_size))

    result = []
    for col in cols:
        values = [r.get(col, "") for r in sample_rows]
        non_empty = [v for v in values if v != ""]
        result.append({"column": col, "type": _infer_column_type(non_empty)})
    return result
