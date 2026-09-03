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

from ._loader import COptions, CPredicate, load

__all__ = ["scan", "ScanError"]

_OP_MAP = {">=": 3, "<=": 5, "!=": 1, "=": 0, ">": 2, "<": 4}
_COND_RE = re.compile(r"^(\w+)\s*(>=|<=|!=|>|<|=)\s*(.+)$")


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


def _parse_where(lib: ctypes.CDLL, ctx: ctypes.c_void_p, where: str) -> list[CPredicate]:
    """Translate a simple "col OP val [AND col OP val ...]" string into
    typed predicates. Only AND is supported — OR would need the C ABI to
    represent more than a flat, implicitly-ANDed predicate list, which is
    more machinery than libscanio's core has needed to earn yet."""
    predicates = []
    for part in where.split(" AND "):
        m = _COND_RE.match(part.strip())
        if not m:
            raise ScanError(f'invalid WHERE condition: "{part.strip()}"')
        col, op, val = m.group(1), m.group(2), m.group(3).strip()
        predicates.append(
            CPredicate(
                column=_resolve_column(lib, ctx, col),
                op=_OP_MAP[op],
                value=val.encode(),
            )
        )
    return predicates


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
               "city = Austin AND revenue > 1000". Operators: = != > >= < <=.
               Only AND is supported.
        limit: Maximum rows to return. Default: no limit.

    Raises:
        ScanError: file not found, malformed WHERE, or unknown column name.
    """
    lib = load()

    # Column names need resolving to indices before the "real" open — the
    # C ABI takes predicates/projection by index, not name, and the header
    # is only known once a file is open. So: open once with no options
    # purely to resolve names, close it, then reopen with the resolved
    # integer-indexed options. Two opens of the same file, not one — but
    # both are mmaps, not reads, so the OS page cache serves the second
    # one; simpler than adding a header-only entry point to the C ABI.
    probe_ctx = lib.scanio_open(path.encode(), None)
    if not probe_ctx:
        _raise_last_error(lib, f"failed to open {path!r}")
    try:
        col_indices = [_resolve_column(lib, probe_ctx, c) for c in columns] if columns else None
        predicates = _parse_where(lib, probe_ctx, where) if where else None
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

    try:
        names = columns if columns else [
            lib.scanio_column_name(ctx, i).decode() for i in range(lib.scanio_n_columns(ctx))
        ]
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
