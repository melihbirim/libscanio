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

# Annotations are never evaluated at runtime here, so PEP 563 lets this
# module keep its type hints without paying `import typing` (3.4ms) on
# every process start. `re` is imported lazily inside _parse_where for
# the same reason (5.0ms) — see _where_patterns(). Both matter because
# the dominant cost of a small-file query is process startup, not the
# scan: on a 1MB file the Zig side finishes in ~2ms.
from __future__ import annotations

import datetime


__all__ = ["validate_to_files", "scan_batches", "validate_batches", "scan", "scan_array", "schema", "count", "aggregate", "topk", "order_by", "profile", "describe", "build_mode", "validate", "validate_report", "validate_iter", "infer_schema", "ValidationReport", "ValidationError", "ScanError"]

_OP_MAP = {">=": 3, "<=": 5, "!=": 1, "=": 0, ">": 2, "<": 4}
_OP_IN = 6
_WHERE_PATTERNS = None


def _where_patterns():
    """(condition, IN) patterns, compiled on first use.

    Deferred so `import re` is paid only by callers that actually pass a
    WHERE clause, not by every import of this module.
    """
    global _WHERE_PATTERNS
    if _WHERE_PATTERNS is None:
        import re

        _WHERE_PATTERNS = (
            re.compile(r"^(\w+)\s*(>=|<=|!=|>|<|=)\s*(.+)$"),
            re.compile(r"^(\w+)\s+IN\s*\((.*)\)$"),
        )
    return _WHERE_PATTERNS


class ScanError(RuntimeError):
    """Raised for a failed open, a malformed WHERE condition, or an unknown column."""


def _backend():
    try:
        from . import _native
    except ImportError as exc:
        raise ScanError("Build the CPython extension: zig build python-extension") from exc
    return _native


def _call(method, *args):
    try:
        return getattr(_backend(), method)(*args)
    except ValueError as exc:
        raise ScanError(str(exc)) from exc


def _path(path):
    import os
    encoded = os.fsencode(os.fspath(path))
    if b"\x00" in encoded:
        raise ValueError("path contains NUL")
    return encoded


def _json(value):
    import json
    return json.dumps(value).encode()


def _resolve_column(names, name):
    try:
        return names.index(name)
    except ValueError:
        raise ScanError(f"unknown column: {name!r}") from None


def _parse_where(names, where):
    """Compile the existing AND/IN syntax into native-owned options once."""
    predicates = []
    cond_re, in_re = _where_patterns()
    for part in where.split(" AND "):
        part = part.strip()
        match = in_re.match(part)
        if match:
            col, values = match.groups()
            values = [v.strip() for v in values.split(",") if v.strip()]
            if not values:
                raise ScanError(f'invalid IN condition (no values): "{part}"')
            predicates.append({"column": _resolve_column(names, col), "op": _OP_IN, "values": values})
            continue
        match = cond_re.match(part)
        if not match:
            raise ScanError(f'invalid WHERE condition: "{part}"')
        col, op, value = match.groups()
        predicates.append({"column": _resolve_column(names, col), "op": _OP_MAP[op], "value": value.strip()})
    return predicates


def _zip_row(names: "Sequence[str]", values: list) -> dict:
    """Map a row's field values onto the header names.

    A row can legitimately carry MORE fields than the header — ragged
    CSV is a real thing and this reader handles it. Indexing `names[i]`
    for those raised IndexError and killed
    the whole iteration mid-scan; they now get a positional `colN` key,
    so the data survives and matches what the `scanio` CLI emits for the
    same row. Fewer fields than the header stays as it was: the missing
    trailing keys are simply absent.

    The common case goes through dict(zip(...)) untouched — this is on
    the per-row path of scan().
    """
    if len(values) <= len(names):
        return dict(zip(names, values))
    row = dict(zip(names, values))
    for i in range(len(names), len(values)):
        row[f"col{i}"] = values[i]
    return row


def scan(path, columns=None, where=None, limit=None, negate=False):
    """Yield matching dictionaries using direct native object construction.

    AND/IN filters, projection, limit and whole-filter negation are supported.
    Each next() consumes one row, preserving early-stop and parse-error timing.
    Close the generator when stopping early.
    """
    ctx = _open_query(path, columns, where, limit, negate)
    try:
        while True:
            rows = _call("next_batch", ctx, 1, 0x7fffffff, True)
            if not rows:
                return
            yield rows[0]
    finally:
        _call("close", ctx)


def _open_query(path, columns=None, where=None, limit=None, negate=False, *,
                _scalar_column=None, _count_only=False):
    path = _path(path)
    probe = _call("query_open", path, b"{}")
    if not columns and not where and limit is None and not negate and _scalar_column is None:
        return probe
    try:
        names = _call("names", probe)
        indices = [_resolve_column(names, c) for c in columns] if columns else None
        predicates = _parse_where(names, where) if where else []
        needed = (indices or []) + [p["column"] for p in predicates]
        if _scalar_column is not None:
            needed.append(_resolve_column(names, _scalar_column))
        options = {"columns": indices, "where": predicates,
                   "limit": limit if limit is not None and limit >= 0 else None,
                   "negate": bool(negate),
                   "max_column": max(needed) if needed and (indices or _scalar_column is not None or _count_only) else None}
    finally:
        _call("close", probe)
    return _call("query_open", path, _json(options))


def scan_array(path, columns=None, where=None, limit=None, as_dict=False, negate=False):
    """Materialize matching rows as tuples or dictionaries, created in CPython.

    With no projection/limit, retain the native parallel columnar collector.
    Projected/limited scans use direct native batches. Memory grows with results.
    """
    ctx = _open_query(path, columns, where, limit, negate)
    try:
        if columns is None and limit is None:
            owner = _call("columnar", ctx)
            return _call("columnar_rows", owner, as_dict)
        result = []
        while True:
            batch = _call("next_batch", ctx, 1024, 1024 * 1024, as_dict)
            if not batch:
                return result
            result.extend(batch)
    finally:
        _call("close", ctx)


def build_mode():
    """Optimization mode of the statically linked CPython native backend."""
    return _backend().build_mode()


def schema(path):
    """Column names in header order, without scanning data rows."""
    ctx = _open_query(path)
    try:
        return _call("names", ctx)
    finally:
        _call("close", ctx)


def count(path, where=None, negate=False):
    """Count matching rows in Zig; unfiltered counts retain the parser-free path."""
    ctx = _open_query(path, where=where, negate=negate, _count_only=True)
    try:
        return _call("count", ctx)
    finally:
        _call("close", ctx)


def aggregate(path, column, where=None):
    """Compute count/sum/min/max/avg in one native pass, skipping non-numbers."""
    ctx = _open_query(path, where=where, _scalar_column=column)
    try:
        index = _resolve_column(_call("names", ctx), column)
        return _call("aggregate", ctx, index)
    finally:
        _call("close", ctx)


def topk(path, column, k, where=None, descending=True):
    """Top K numeric rows, best first; each dictionary includes its numeric _key."""
    ctx = _open_query(path, where=where)
    try:
        index = _resolve_column(_call("names", ctx), column)
        return _call("sort", ctx, index, k, descending, True)
    finally:
        _call("close", ctx)


def order_by(path, column, where=None, descending=False):
    """Materialize matching rows and sort numerically, with string fallback."""
    ctx = _open_query(path, where=where)
    try:
        index = _resolve_column(_call("names", ctx), column)
        return _call("sort", ctx, index, 0, descending, False)
    finally:
        _call("close", ctx)


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


# ── import validation ────────────────────────────────────────────────


class ValidationError:
    """One failed rule, on one cell. `column` is None for a structural
    error (`too_few_fields` / `too_many_fields`), which is about the
    row's shape rather than any single value.

    Hand-written rather than a NamedTuple or a dataclass on purpose:
    both cost an `import typing` (15ms) or `import collections` (1.8ms)
    at module load, and this module goes to some length to import in
    ~3ms — see the note at the top of the file. Nothing here needs more
    than __slots__.
    """

    __slots__ = ("row", "column", "column_name", "rule", "value")

    def __init__(self, row, column, column_name, rule, value):
        self.row = row
        self.column = column
        self.column_name = column_name
        self.rule = rule
        self.value = value

    def __eq__(self, other):
        if not isinstance(other, ValidationError):
            return NotImplemented
        return all(getattr(self, f) == getattr(other, f) for f in self.__slots__)

    def __hash__(self):
        return hash(tuple(getattr(self, f) for f in self.__slots__))

    def __repr__(self):
        return (
            f"ValidationError(row={self.row}, column={self.column!r}, "
            f"column_name={self.column_name!r}, rule={self.rule!r}, value={self.value!r})"
        )

    def as_dict(self) -> dict:
        return {f: getattr(self, f) for f in self.__slots__}


class ValidationReport:
    """The result of a full pre-flight pass.

    `errors` is capped at `max_errors`; `errors_total` and `counts` are
    complete regardless, so a truncated report still tells you the true
    scale of the problem. `truncated` says whether the cap was hit.
    """

    __slots__ = (
        "rows_total",
        "rows_valid",
        "rows_invalid",
        "errors_total",
        "truncated",
        "counts",
        "errors",
    )

    def __init__(self, rows_total, rows_valid, rows_invalid, errors_total, truncated, counts, errors):
        self.rows_total = rows_total
        self.rows_valid = rows_valid
        self.rows_invalid = rows_invalid
        self.errors_total = errors_total
        self.truncated = truncated
        self.counts = counts
        self.errors = errors

    @property
    def ok(self) -> bool:
        return self.rows_invalid == 0

    def __eq__(self, other):
        if not isinstance(other, ValidationReport):
            return NotImplemented
        return all(getattr(self, f) == getattr(other, f) for f in self.__slots__)

    def __repr__(self):
        return (
            f"ValidationReport(rows_total={self.rows_total}, rows_valid={self.rows_valid}, "
            f"rows_invalid={self.rows_invalid}, errors_total={self.errors_total}, "
            f"truncated={self.truncated}, counts={self.counts!r}, "
            f"errors=[{len(self.errors)} shown])"
        )

    def as_dict(self) -> dict:
        d = {f: getattr(self, f) for f in self.__slots__}
        d["errors"] = [e.as_dict() for e in self.errors]
        return d


def _validation_errors(raw: list) -> list[ValidationError]:
    return [
        ValidationError(e["row"], e["column"], e["column_name"], e["rule"], e["value"])
        for e in raw
    ]


def validate(source, schema: dict, *, mode="fast", format=None):
    """Validate a file path or uploaded bytes entirely in Zig.

    Default ``fast`` returns bool, stopping at the first invalid record.
    ``full`` returns all failed records as {values: [...], errors: [...]}.
    Values are positional to preserve duplicate headers and ragged rows;
    errors contain column, column_name, rule and value (no row numbers).
    Full mode uses memory proportional to rejected data, with no error cap.

    Bytes default to CSV; specify format="ndjson" or "json" for JSON input.
    Paths infer format from their extension. File-like streams are not accepted.
    Invalid input/schema or parser failures raise ScanError. Fast mode does
    not examine the remainder after a validation failure.
    The previous summary API is available as validate_report().
    """
    import json
    import os

    if mode not in ("fast", "full"):
        raise ValueError("mode must be 'fast' or 'full'")
    if isinstance(source, bytes):
        formats = {None: 1, "csv": 1, "ndjson": 2, "json": 2}
        if format not in formats:
            raise ValueError("format must be csv, ndjson or json")
        data, source_format = source, formats[format]
    else:
        if format is not None:
            raise ValueError("format is only supported for bytes input")
        data = os.fsencode(os.fspath(source))
        if b"\x00" in data:
            raise ValueError("path contains NUL")
        source_format = 0
    try:
        from . import _native
    except ImportError as exc:
        raise ScanError("Build the CPython extension: zig build python-extension (requires setuptools and a C compiler)") from exc
    try:
        return _native.validate(data, json.dumps(schema).encode(), source_format, mode == "full")
    except ValueError as exc:
        raise ScanError(str(exc)) from exc


def validate_report(path, schema, max_errors=100):
    """Scan every row, count every failure, and retain a capped error report.

    max_errors=0 retains the historical default of 100 stored errors.
    """
    ctx = _call("validator_open", _path(path), _json(schema))
    try:
        raw = _call("report", ctx, max_errors)
    finally:
        _call("close", ctx)
    raw["errors"] = _validation_errors(raw["errors"])
    return ValidationReport(**raw)


def validate_iter(path, schema):
    """Yield every (row dict, ValidationError list), without intermediate JSON."""
    ctx = _call("validator_open", _path(path), _json(schema))
    try:
        while True:
            batch = _call("next_batch", ctx, 1, 0x7fffffff, True)
            if not batch:
                return
            row, errors = batch[0]
            yield row, _validation_errors(errors)
    finally:
        _call("close", ctx)


def infer_schema(path: str, sample_size: int = 1000, required: bool = False) -> dict:
    """Draft a schema from what the file already looks like, using
    `describe()`'s sampled type inference.

    A starting point to edit, not a schema to trust: it can only describe
    the file it read, so a column that is 100% integers in the sample
    becomes `{"type": "integer"}` even if the real rule is narrower — and
    a file that is entirely wrong will infer a schema it passes cleanly.
    Print it, fix it, then pass it to `validate()`.

    `required=True` marks every column required, which is usually closer
    to a real import's intent than the default of marking none.
    """
    out: dict = {}
    for col in describe(path, sample_size=sample_size):
        rule: dict = {}
        # "empty" means the sample had no values at all — inferring a
        # type from nothing would be a guess, so only the presence rule
        # (if asked for) survives.
        if col["type"] not in ("string", "empty"):
            rule["type"] = col["type"]
        if required:
            rule["required"] = True
        out[col["column"]] = rule
    return out


def _check_batch_options(batch_size, target_bytes):
    if type(batch_size) is not int or not 1 <= batch_size <= 65536:
        raise ValueError("batch_size must be an integer in 1..65536")
    if type(target_bytes) is not int or not 1 <= target_bytes <= 0x7fffffff:
        raise ValueError("target_bytes must be an integer in 1..2147483647")


def scan_batches(path, columns=None, where=None, limit=None, negate=False, *,
                 batch_size=1024, target_bytes=1024 * 1024, as_dict=True):
    """Yield direct CPython batches with scan()'s query semantics.

    The byte budget retains its former JSON-encoded-size meaning, calculated
    without serialization. A row may exceed it. A parse error discards the
    current batch; previous batches own their data. Close on early exit.
    """
    _check_batch_options(batch_size, target_bytes)
    ctx = _open_query(path, columns, where, limit, negate)
    try:
        while True:
            batch = _call("next_batch", ctx, batch_size, target_bytes, as_dict)
            if not batch:
                return
            yield batch
    finally:
        _call("close", ctx)


def validate_batches(path, schema, *, batch_size=1024, target_bytes=1024 * 1024,
                     as_dict=True):
    """Yield native batches of (row, ValidationError list), with all errors."""
    _check_batch_options(batch_size, target_bytes)
    ctx = _call("validator_open", _path(path), _json(schema))
    try:
        while True:
            batch = _call("next_batch", ctx, batch_size, target_bytes, as_dict)
            if not batch:
                return
            yield [(row, _validation_errors(errors)) for row, errors in batch]
    finally:
        _call("close", ctx)


def validate_to_files(path, schema, accepted_path, rejected_path):
    """Route valid CSV and rejected JSONL in Zig. Output paths must not exist.

    UTF-8 required. Newly created outputs are removed on failure (best effort).
    This returns counts directly through CPython; no fsync is implied.
    """
    return _call("validate_to_files", _path(path), _json(schema),
                 _path(accepted_path), _path(rejected_path))
