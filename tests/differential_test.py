#!/usr/bin/env python3
"""Differential test: every client must give the same answer, and that
answer must be the right one.

Each binding re-implements the same query on top of the same Zig core,
but through a different path — ctypes over the C ABI (Python), N-API
(Node), and a direct link (the CLI). The existing per-binding suites each
check their own path in isolation, which cannot catch the failure mode
that actually bit this project: two clients quietly disagreeing about the
same file. Node's `scan()` dropped fields past the header while its own
`scanArray()` kept them, and Python raised IndexError on the same row —
three answers, one file, and every suite green.

So this runs a matrix of queries through all three clients AND against a
plain-Python oracle that re-implements libscanio's documented semantics
(see `oracle_rows` below) with nothing but the `csv`/`json` modules. An
oracle matters: if all three clients share a bug in the Zig core they
agree with each other perfectly.

Usage: python3 tests/differential_test.py
Requires: node on PATH, the C ABI lib and the N-API addon built.
    zig build c-lib -Doptimize=ReleaseFast
    zig build node   -Doptimize=ReleaseFast
    zig build cli    -Doptimize=ReleaseFast
"""
import csv
import re
import json
import math
import os
import subprocess
import sys
import tempfile

# text=True decodes a child's stdout with the LOCALE encoding, which is
# cp1252 on a Windows runner — it turned Node's and the CLI's correct
# UTF-8 output into mojibake before the comparison, and reported the
# Python client (the one that was right) as the odd one out. Every
# subprocess below therefore passes encoding="utf-8" explicitly. Our own
# report needs the same treatment or the failure text is unreadable in
# the CI log.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "python"))
import libscanio  # noqa: E402

# .exe on Windows — zig-out/bin/scanio does not exist there, and the
# check below would report the CLI as unbuilt on a runner that had just
# built it (which is exactly how this failed in CI).
CLI = os.path.join(REPO, "zig-out", "bin", "scanio.exe" if sys.platform == "win32" else "scanio")

passed = 0
failed = 0


def check(label, actual, expected):
    global passed, failed
    if actual == expected:
        passed += 1
    else:
        failed += 1
        print(f"FAIL  {label}\n    expected: {expected!r}\n    actual:   {actual!r}")


# ── the oracle ────────────────────────────────────────────────────────
# libscanio's semantics, re-implemented independently. Deliberately the
# dumbest possible version: no shared code with the clients.


def parse_numeric(s):
    """A field is 'a number' only if it parses AND is finite.

    Matches query.zig's parseNumeric: "nan"/"inf" are text, not
    arithmetic, or one such cell poisons a whole column.
    """
    try:
        v = float(s)
    except (ValueError, TypeError):
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v


def eval_one(field, op, value):
    if op == "IN":
        for v in value:
            pv, fv = parse_numeric(v), parse_numeric(field)
            if pv is not None and fv is not None:
                if fv == pv:
                    return True
                continue
            if field == v:
                return True
        return False
    pv = parse_numeric(value)
    if pv is not None:
        fv = parse_numeric(field)
        if fv is not None:
            return {"=": fv == pv, "!=": fv != pv, ">": fv > pv,
                    ">=": fv >= pv, "<": fv < pv, "<=": fv <= pv}[op]
    # Non-numeric on either side: byte-wise string comparison.
    fb, vb = field.encode(), value.encode()
    return {"=": fb == vb, "!=": fb != vb, ">": fb > vb,
            ">=": fb >= vb, "<": fb < vb, "<=": fb <= vb}[op]


def parse_where_for_oracle(where):
    """The WHERE string as (column, op, value) triples, for the oracle.
    Deliberately a separate hand-rolled parse from the library's own —
    an oracle that shared the parser would not be independent of it."""
    preds = []
    if not where:
        return preds
    for part in where.split(" AND "):
        if " IN " in part:
            col, rest = part.split(" IN ", 1)
            preds.append((col.strip(), "IN", [v.strip() for v in rest.strip()[1:-1].split(",")]))
        else:
            for op in (">=", "<=", "!=", ">", "<", "="):
                if op in part:
                    c, v = part.split(op, 1)
                    preds.append((c.strip(), op, v.strip()))
                    break
    return preds


def oracle_rows(path, header, preds, columns=None, limit=None, negate=False):
    """Rows the query should return, as lists of field values."""
    out = []
    for fields in read_raw(path):
        row = {}
        for i, f in enumerate(fields):
            row[header[i] if i < len(header) else f"col{i}"] = f
        ok = True
        for col, op, val in preds:
            idx = header.index(col)
            if idx >= len(fields):  # Row.get() past the end is null -> no match
                ok = False
                break
            if not eval_one(fields[idx], op, val):
                ok = False
                break
        # negate inverts the whole conjunction, so a row that failed
        # ANY clause is the one to keep.
        if ok == negate:
            continue
        if columns:
            out.append([fields[header.index(c)] if header.index(c) < len(fields) else "" for c in columns])
        else:
            # Header-width, matching how all three clients are read here
            # (by column name, missing -> ""). Fields PAST the header are
            # checked separately, by the per-client suites, because they
            # only exist in the dict/array shapes and have no header name
            # to look up.
            out.append([fields[i] if i < len(fields) else "" for i in range(len(header))])
        if limit is not None and len(out) >= limit:
            break
    return out


def read_raw(path):
    """Split a fixture independently of libscanio. For CSV that means
    Python's own csv.reader: since the reader gained RFC 4180 quoting,
    the stdlib module is a genuinely independent implementation of the
    same contract, which is exactly what an oracle should be. (The one
    case they disagree on — a quoted field spanning a newline — the
    reader rejects outright and no fixture contains.)"""
    if path.endswith(".ndjson"):
        header = None
        for line in open(path, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line:
                continue
            obj = json.loads(line)
            if header is None:
                header = list(obj.keys())
            yield [render(obj.get(k, "")) for k in header]
    else:
        with open(path, encoding="utf-8") as f:
            lines = [ln.rstrip("\n").rstrip("\r") for ln in f if ln.strip() != ""]
        for fields in list(csv.reader(lines))[1:]:
            yield fields


def render(v):
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def header_of(path):
    if path.endswith(".ndjson"):
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    return list(json.loads(line).keys())
    with open(path, encoding="utf-8") as f:
        return next(csv.reader([f.readline().rstrip("\n").rstrip("\r")]))


# ── the three clients ─────────────────────────────────────────────────


def via_python(path, where, columns, limit, negate=False):
    kw = {}
    if where:
        kw["where"] = where
    if columns:
        kw["columns"] = columns
    if limit is not None:
        kw["limit"] = limit
    if negate:
        kw["negate"] = True
    names = columns or header_of(path)
    out = []
    for row in libscanio.scan(path, **kw):
        out.append([row.get(n, "") for n in names])
    return out


NODE_API_DRIVER = r"""
// One process, several calls — the per-API drivers below all go through
// this so a Node startup isn't paid per assertion.
const ls = require(process.argv[2]);
const file = process.argv[3];
const out = {};
try {
  out.schema = ls.schema(file);
  out.count = ls.count(file);
  out.aggregate_amount = ls.aggregate(file, 'amount');
  out.aggregate_amount_where = ls.aggregate(file, 'amount', 'city = London');
  out.topk = ls.topk(file, 'amount', 3);
  out.topk_asc = ls.topk(file, 'amount', 3, null, false);
  out.orderBy = ls.orderBy(file, 'amount');
  out.orderBy_desc = ls.orderBy(file, 'amount', null, true);
  out.orderBy_where = ls.orderBy(file, 'amount', 'city = London');
} catch (e) {
  out.error = String(e && e.message);
}
process.stdout.write(JSON.stringify(out));
"""


def node_api_calls(path):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(NODE_API_DRIVER)
        driver = f.name
    try:
        p = subprocess.run(["node", driver, os.path.join(REPO, "node", "index.js"), path],
                           capture_output=True, encoding="utf-8")
        if p.returncode != 0:
            raise AssertionError(f"node api driver failed: {p.stderr}")
        return json.loads(p.stdout)
    finally:
        os.unlink(driver)


NODE_DRIVER = r"""
const ls = require(process.argv[2]);
const [, , , file, where, columns, limit, negate] = process.argv;
(async () => {
  const opts = {};
  if (where !== '-') opts.where = where;
  if (columns !== '-') opts.columns = columns.split(',');
  if (limit !== '-') opts.limit = Number(limit);
  if (negate === '1') opts.negate = true;
  const rows = [];
  for await (const r of ls.scan(file, opts)) rows.push(r);
  process.stdout.write(JSON.stringify(rows));
})().catch((e) => { process.stderr.write(String(e && e.message)); process.exit(1); });
"""


def via_node(path, where, columns, limit, negate=False):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(NODE_DRIVER)
        driver = f.name
    try:
        p = subprocess.run(
            ["node", driver, os.path.join(REPO, "node", "index.js"), path,
             where or "-", ",".join(columns) if columns else "-",
             str(limit) if limit is not None else "-", "1" if negate else "0"],
            capture_output=True, encoding="utf-8")
        if p.returncode != 0:
            raise AssertionError(f"node driver failed: {p.stderr}")
        names = columns or header_of(path)
        return [[r.get(n, "") for n in names] for r in json.loads(p.stdout)]
    finally:
        os.unlink(driver)


def via_cli(path, where, columns, limit, negate=False):
    cmd = [CLI, path, "--format", "ndjson"]
    if where:
        cmd += ["--where", where]
    if negate:
        cmd += ["--not"]
    if columns:
        cmd += ["--columns", ",".join(columns)]
    if limit is not None:
        cmd += ["--limit", str(limit)]
    p = subprocess.run(cmd, capture_output=True, encoding="utf-8")
    if p.returncode != 0:
        raise AssertionError(f"cli failed: {p.stderr}")
    names = columns or header_of(path)
    out = []
    for line in p.stdout.splitlines():
        if not line:
            continue
        obj = json.loads(line)
        out.append([obj.get(n, "") for n in names])
    return out


# ── fixtures ──────────────────────────────────────────────────────────

FIXTURES = {}


def write_fixtures(tmp):
    csv_path = os.path.join(tmp, "d.csv")
    with open(csv_path, "w", encoding="utf-8") as f:
        f.write("id,name,amount,city\n")
        f.write("1,Alice,100,London\n")
        f.write("2,Bob,-5,Paris\n")
        f.write("3,Carol,0,London\n")
        f.write("4,dave,1e3,Berlin\n")      # exponent notation is numeric
        f.write("5,Eve,,Paris\n")           # empty field
        f.write("6,Frank,nan,London\n")     # literal "nan" is text, not a number
        f.write("7,Grace,3.50,Zürich\n")    # non-ASCII, trailing-zero float
        f.write("8,Heidi,1000,London\n")
        f.write("9,Ivan,999999999999,Paris\n")
        f.write("10,Judy,7,\n")             # empty trailing field
    FIXTURES["csv"] = csv_path

    nd_path = os.path.join(tmp, "d.ndjson")
    with open(nd_path, "w", encoding="utf-8") as f:
        for i, (name, amt, city) in enumerate([
            ("Alice", 100, "London"), ("Bob", -5, "Paris"), ("Carol", 0, "London"),
            ("dave", 1000, "Berlin"), ("Eve", "", "Paris"), ("Frank", "nan", "London"),
            ("Grace", 3.5, "Zürich"), ("Heidi", 1000, "London"),
            ("Ivan", 999999999999, "Paris"), ("Judy", 7, ""),
        ], start=1):
            f.write(json.dumps({"id": i, "name": name, "amount": amt, "city": city}) + "\n")
    FIXTURES["ndjson"] = nd_path

    # RFC 4180 quoting: a delimiter inside quotes, a doubled quote, a
    # quote that is ordinary data because it is not at the field start,
    # and an empty quoted field. Column names are quoted too — the
    # header goes through the same splitter as every other row.
    quoted = os.path.join(tmp, "quoted.csv")
    with open(quoted, "w", encoding="utf-8") as f:
        f.write('id,"name",amount,city\n')
        f.write('1,"Smith, John",100,London\n')
        f.write('2,"He said ""hi""",-5,Paris\n')
        f.write('3,he said "hi",0,London\n')
        f.write('4,"",1000,"Berlin, DE"\n')
        f.write('5,Eve,7,"Zürich"\n')
    FIXTURES["quoted"] = quoted

    # Deliberately varied: every rule in VALIDATION_CASES has to have
    # both a passing and a failing row here, or the comparison proves
    # nothing about that rule.
    val = os.path.join(tmp, "validate.csv")
    with open(val, "w", encoding="utf-8") as f:
        f.write("id,name,amount,city\n")
        f.write("1,Alice,100,London\n")       # clean
        f.write("x,Bob,50,Paris\n")           # id not an integer
        f.write("3,,-5,Berlin\n")             # name blank; amount below min
        f.write("4,Bo,-5,London\n")           # name too short; amount below min
        f.write("5,Alexandra,2000,Tokyo\n")   # name too long; amount above max; city not in set
        f.write("6,Carol,,   \n")             # amount blank; city whitespace-only
        f.write("7,Dave, 3.5 ,Paris\n")       # clean; a padded number is still a number
        f.write("8,Eve,nan,London\n")         # "nan" is text, not a number
    FIXTURES["validate"] = val

    ragged = os.path.join(tmp, "ragged.csv")
    with open(ragged, "w", encoding="utf-8") as f:
        f.write("a,b,c\n1,2,3\n4,5\n6\n7,8,9,EXTRA\n")
    FIXTURES["ragged"] = ragged


QUERIES = [
    (None, None, None),
    ("amount > 50", None, None),
    ("amount >= 100", None, None),
    ("amount < 0", None, None),
    ("amount <= 0", None, None),
    ("amount = 100", None, None),
    ("amount != 100", None, None),
    ("city = London", None, None),
    ("city != London", None, None),
    ("name = dave", None, None),
    ("city = Zürich", None, None),
    ("amount = nan", None, None),
    ("city IN (London, Paris)", None, None),
    ("amount IN (100, 7)", None, None),
    ("amount > 50 AND city = London", None, None),
    ("city = London AND amount < 1000", None, None),
    (None, ["name", "city"], None),
    ("city = London", ["id", "amount"], None),
    (None, ["city", "id"], None),
    (None, None, 3),
    ("city = London", None, 2),
    ("city = London", ["name"], 1),
    ("amount > 999999999", None, None),
]


# ── validation: an independent oracle, plus all three clients ────────
#
# The rules live in Zig so the three clients cannot drift apart. That is
# only worth asserting against something that did NOT come from Zig, so
# the checks below are written here from the documented rule semantics,
# not ported from src/validate.zig.

_ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_ISO_DATETIME = re.compile(
    r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|z|[+-]\d{2}:\d{2})?$"
)


def _oracle_blank(v):
    return v.strip(" \t\r\n") == ""


def _oracle_is_type(t, v):
    if t in (None, "any", "string"):
        return True
    if t == "integer":
        s = v.strip(" \t")
        body = s[1:] if s[:1] in ("+", "-") else s
        return bool(body) and body.isdigit() and body.isascii()
    if t == "float":
        try:
            f = float(v.strip(" \t"))
        except ValueError:
            return False
        return f == f and f not in (float("inf"), float("-inf"))
    if t == "boolean":
        return v.strip(" \t").lower() in ("true", "false")
    if t == "datetime":
        s = v.strip(" \t")
        if not (_ISO_DATE.match(s) or _ISO_DATETIME.match(s)):
            return False
        month, day = int(s[5:7]), int(s[8:10])
        if not (1 <= month <= 12 and 1 <= day <= 31):
            return False
        if len(s) > 10:
            hour, minute = int(s[11:13]), int(s[14:16])
            if hour > 23 or minute > 59:
                return False
        return True
    raise AssertionError(f"oracle does not know type {t!r}")


def _oracle_number(v):
    try:
        f = float(v.strip(" \t"))
    except ValueError:
        return None
    return f if f == f and f not in (float("inf"), float("-inf")) else None


def oracle_validate(path, schema, max_errors=100):
    """Rebuilds the report from the documented rules, independently."""
    header = header_of(path)
    errors, counts = [], {}
    rows_total = rows_valid = rows_invalid = errors_total = 0

    def note(row_no, col, name, rule, value):
        nonlocal errors_total
        errors_total += 1
        counts[rule] = counts.get(rule, 0) + 1
        if len(errors) < max_errors:
            errors.append({"row": row_no, "column": col, "column_name": name,
                           "rule": rule, "value": value})

    for fields in read_raw(path):
        rows_total += 1
        before = errors_total
        if len(fields) < len(header):
            note(rows_total, None, "", "too_few_fields", "")
        elif len(fields) > len(header):
            note(rows_total, None, "", "too_many_fields", "")

        for name, rule in schema.items():
            idx = header.index(name)
            if idx >= len(fields):
                continue
            v = fields[idx]
            if _oracle_blank(v):
                if rule.get("required"):
                    note(rows_total, idx, name, "missing_required", v)
                continue
            if not _oracle_is_type(rule.get("type"), v):
                note(rows_total, idx, name, "bad_type", v)
                continue
            if "min" in rule or "max" in rule:
                n = _oracle_number(v)
                if n is None:
                    note(rows_total, idx, name, "bad_type", v)
                else:
                    if "min" in rule and n < rule["min"]:
                        note(rows_total, idx, name, "below_min", v)
                    if "max" in rule and n > rule["max"]:
                        note(rows_total, idx, name, "above_max", v)
            if "min_len" in rule and len(v) < rule["min_len"]:
                note(rows_total, idx, name, "too_short", v)
            if "max_len" in rule and len(v) > rule["max_len"]:
                note(rows_total, idx, name, "too_long", v)
            if "one_of" in rule and v not in [str(x) for x in rule["one_of"]]:
                note(rows_total, idx, name, "not_in_set", v)

        if errors_total == before:
            rows_valid += 1
        else:
            rows_invalid += 1

    return {"rows_total": rows_total, "rows_valid": rows_valid,
            "rows_invalid": rows_invalid, "errors_total": errors_total,
            "truncated": errors_total > len(errors), "counts": counts,
            "errors": errors}


def validate_via_python(path, schema, max_errors=100):
    r = libscanio.validate(path, schema, max_errors=max_errors)
    return {"rows_total": r.rows_total, "rows_valid": r.rows_valid,
            "rows_invalid": r.rows_invalid, "errors_total": r.errors_total,
            "truncated": r.truncated, "counts": r.counts,
            "errors": [e.as_dict() for e in r.errors]}


NODE_VALIDATE_DRIVER = r"""
const ls = require(process.argv[2]);
const [, , , file, schemaJson, maxErrors] = process.argv;
(async () => {
  const schema = JSON.parse(schemaJson);
  const r = ls.validate(file, schema, { maxErrors: Number(maxErrors) });
  const streamed = [];
  for await (const v of ls.validateIter(file, schema)) {
    streamed.push({ number: v.number, values: Object.values(v.row), errors: v.errors });
  }
  process.stdout.write(JSON.stringify({
    rows_total: r.rowsTotal, rows_valid: r.rowsValid, rows_invalid: r.rowsInvalid,
    errors_total: r.errorsTotal, truncated: r.truncated, counts: r.counts,
    errors: r.errors, streamed,
  }));
})().catch((e) => { process.stderr.write(String(e && e.message)); process.exit(1); });
"""


def validate_via_node(path, schema, max_errors=100):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(NODE_VALIDATE_DRIVER)
        driver = f.name
    try:
        p = subprocess.run(
            ["node", driver, os.path.join(REPO, "node", "index.js"), path,
             json.dumps(schema), str(max_errors)],
            capture_output=True, encoding="utf-8")
        if p.returncode != 0:
            raise AssertionError(f"node validate driver failed: {p.stderr}")
        return json.loads(p.stdout)
    finally:
        os.unlink(driver)


def validate_via_cli(path, schema, tmp):
    schema_path = os.path.join(tmp, "schema.json")
    with open(schema_path, "w", encoding="utf-8") as f:
        json.dump(schema, f)
    p = subprocess.run([CLI, path, "--validate", schema_path],
                       capture_output=True, encoding="utf-8")
    # Exit 1 means "rows failed", which is the point of report mode — not
    # a command failure.
    if p.returncode not in (0, 1):
        raise AssertionError(f"cli validate failed: {p.stderr}")
    return json.loads(p.stdout), p.returncode


def cli_validate_rows(path, schema, tmp, mode):
    schema_path = os.path.join(tmp, "schema.json")
    with open(schema_path, "w", encoding="utf-8") as f:
        json.dump(schema, f)
    p = subprocess.run([CLI, path, "--validate", schema_path, mode, "--format", "ndjson"],
                       capture_output=True, encoding="utf-8")
    if p.returncode != 0:
        raise AssertionError(f"cli {mode} failed: {p.stderr}")
    return [json.loads(l) for l in p.stdout.splitlines() if l]


VALIDATION_CASES = [
    ("types", {"id": {"type": "integer"}, "amount": {"type": "float"}}),
    ("required", {"name": {"required": True}, "city": {"required": True}}),
    ("ranges", {"amount": {"min": 0, "max": 1000}}),
    ("lengths", {"name": {"min_len": 3, "max_len": 5}}),
    ("enum", {"city": {"one_of": ["London", "Paris"]}}),
    ("everything", {"id": {"type": "integer", "required": True},
                    "name": {"required": True, "max_len": 5},
                    "amount": {"type": "float", "min": 0, "max": 1000},
                    "city": {"one_of": ["London", "Paris", "Berlin"]}}),
    ("nothing", {}),
]


def main():
    if not os.path.exists(CLI):
        print(f"missing {CLI} — run: zig build cli -Doptimize=ReleaseFast")
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        write_fixtures(tmp)

        for kind in ("csv", "ndjson", "quoted"):
            path = FIXTURES[kind]
            header = header_of(path)
            for where, columns, limit in QUERIES:
                preds = parse_where_for_oracle(where)
                want = oracle_rows(path, header, preds, columns, limit)
                label = f"{kind} where={where!r} cols={columns} limit={limit}"
                py = via_python(path, where, columns, limit)
                nd = via_node(path, where, columns, limit)
                cl = via_cli(path, where, columns, limit)
                check(f"oracle == python   | {label}", py, want)
                check(f"python == node     | {label}", nd, py)
                check(f"python == cli      | {label}", cl, py)

        # count() must agree with the number of rows the scan returns.
        for kind in ("csv", "ndjson", "quoted", "ragged"):
            path = FIXTURES[kind]
            for where in (None, "a = 1" if kind == "ragged" else "city = London"):
                n_scan = len(via_python(path, where, None, None))
                n_count = libscanio.count(path, where) if where else libscanio.count(path)
                check(f"count == len(scan) | {kind} where={where!r}", n_count, n_scan)
                cli_cmd = [CLI, path, "--count"] + (["--where", where] if where else [])
                cli_n = int(subprocess.run(cli_cmd, capture_output=True, encoding="utf-8").stdout.strip())
                check(f"count == cli count | {kind} where={where!r}", cli_n, n_count)

        # The rest of the API surface: aggregate/topk/orderBy/schema are
        # separate code paths in each client (Node re-derives topk/orderBy
        # rows from its own JSON, Python from the C ABI's row buffers), so
        # scan() agreeing proves nothing about them.
        for kind in ("csv", "ndjson", "quoted"):
            path = FIXTURES[kind]
            nd = node_api_calls(path)
            check(f"schema    | {kind}", nd["schema"], libscanio.schema(path))
            check(f"count     | {kind}", nd["count"], libscanio.count(path))

            py_agg = libscanio.aggregate(path, "amount")
            check(f"aggregate | {kind}", nd["aggregate_amount"], py_agg)
            check(f"aggregate+where | {kind}", nd["aggregate_amount_where"],
                  libscanio.aggregate(path, "amount", "city = London"))
            # And against the oracle: "nan"/empty are skipped, not summed.
            vals = [parse_numeric(r[header_of(path).index("amount")])
                    for r in oracle_rows(path, header_of(path), [])]
            nums = [v for v in vals if v is not None]
            check(f"aggregate == oracle count | {kind}", py_agg["count"], len(nums))
            check(f"aggregate == oracle sum   | {kind}", round(py_agg["sum"], 6), round(sum(nums), 6))
            check(f"aggregate == oracle min   | {kind}", py_agg["min"], min(nums))
            check(f"aggregate == oracle max   | {kind}", py_agg["max"], max(nums))

            py_topk = [dict(r) for r in libscanio.topk(path, "amount", 3)]
            check(f"topk desc | {kind}", nd["topk"], py_topk)
            check(f"topk asc  | {kind}", nd["topk_asc"],
                  [dict(r) for r in libscanio.topk(path, "amount", 3, descending=False)])
            # top-K must be the k largest numeric values, in order.
            check(f"topk == oracle | {kind}", [r["_key"] for r in py_topk],
                  sorted(nums, reverse=True)[:3])

            check(f"orderBy   | {kind}", nd["orderBy"],
                  [dict(r) for r in libscanio.order_by(path, "amount")])
            check(f"orderBy desc | {kind}", nd["orderBy_desc"],
                  [dict(r) for r in libscanio.order_by(path, "amount", descending=True)])
            check(f"orderBy+where | {kind}", nd["orderBy_where"],
                  [dict(r) for r in libscanio.order_by(path, "amount", "city = London")])
            # Ordering must be stable-in-value: ascending then reversed
            # gives the same multiset of keys as descending.
            asc = [r["amount"] for r in libscanio.order_by(path, "amount")]
            desc = [r["amount"] for r in libscanio.order_by(path, "amount", descending=True)]
            check(f"orderBy asc/desc are mirrors | {kind}", sorted(asc), sorted(desc))
            check(f"orderBy returns every row | {kind}", len(asc), libscanio.count(path))

        # Ragged rows: the three clients must agree field-for-field.
        path = FIXTURES["ragged"]
        py = via_python(path, None, None, None)
        check("ragged | python == node", via_node(path, None, None, None), py)
        check("ragged | python == cli", via_cli(path, None, None, None), py)
        check("ragged | oracle == python", py, oracle_rows(path, header_of(path), []))

        # ── validation: oracle vs python vs node vs CLI ──────────────
        vpath = FIXTURES["validate"]
        for label, schema in VALIDATION_CASES:
            want = oracle_validate(vpath, schema)
            py = validate_via_python(vpath, schema)
            nd = validate_via_node(vpath, schema)
            cli, cli_code = validate_via_cli(vpath, schema, tmp)
            streamed = nd.pop("streamed")

            check(f"validate | oracle == python | {label}", py, want)
            check(f"validate | python == node   | {label}", nd, py)
            check(f"validate | python == cli    | {label}", cli, py)
            check(f"validate | cli exit code is the gate | {label}",
                  cli_code, 1 if want["rows_invalid"] else 0)

            # The streaming API has to agree with the report built from
            # it: same rows clean, same rules broken, same order.
            check(f"validate | validateIter row count | {label}",
                  len(streamed), want["rows_total"])
            check(f"validate | validateIter clean rows | {label}",
                  sum(1 for v in streamed if not v["errors"]), want["rows_valid"])
            check(f"validate | validateIter rules match the report | {label}",
                  [e["rule"] for v in streamed for e in v["errors"]][: len(want["errors"])],
                  [e["rule"] for e in want["errors"]])

            # And the CLI's two row modes must partition the file
            # exactly the way the report says.
            valid_rows = cli_validate_rows(vpath, schema, tmp, "--valid")
            invalid_rows = cli_validate_rows(vpath, schema, tmp, "--invalid")
            check(f"validate | cli --valid count | {label}", len(valid_rows), want["rows_valid"])
            check(f"validate | cli --invalid count | {label}", len(invalid_rows), want["rows_invalid"])
            check(f"validate | cli --valid + --invalid is every row | {label}",
                  len(valid_rows) + len(invalid_rows), want["rows_total"])

        # Truncation: the stored list is capped, the totals are not — and
        # all three clients must cap identically.
        big_schema = VALIDATION_CASES[-1][1]
        for cap in (1, 3):
            want = oracle_validate(vpath, big_schema, max_errors=cap)
            py = validate_via_python(vpath, big_schema, max_errors=cap)
            nd = validate_via_node(vpath, big_schema, max_errors=cap)
            nd.pop("streamed")
            check(f"validate | oracle == python | max_errors={cap}", py, want)
            check(f"validate | python == node   | max_errors={cap}", nd, py)

        # Structural errors, on the ragged fixture the rest of this
        # suite already uses.
        rag_schema = {"a": {"required": True}}
        want = oracle_validate(FIXTURES["ragged"], rag_schema)
        py = validate_via_python(FIXTURES["ragged"], rag_schema)
        nd = validate_via_node(FIXTURES["ragged"], rag_schema)
        nd.pop("streamed")
        check("validate | oracle == python | ragged", py, want)
        check("validate | python == node   | ragged", nd, py)

        # A schema that names a column the file does not have must fail
        # in every client, not quietly enforce nothing in some of them.
        bad = {"does_not_exist": {"required": True}}
        try:
            validate_via_python(vpath, bad)
            check("validate | python rejects an unknown column", "no error", "an error")
        except libscanio.ScanError:
            check("validate | python rejects an unknown column", True, True)
        try:
            validate_via_node(vpath, bad)
            check("validate | node rejects an unknown column", "no error", "an error")
        except AssertionError:
            check("validate | node rejects an unknown column", True, True)
        schema_path = os.path.join(tmp, "bad_schema.json")
        with open(schema_path, "w", encoding="utf-8") as f:
            json.dump(bad, f)
        rc = subprocess.run([CLI, vpath, "--validate", schema_path],
                            capture_output=True, encoding="utf-8").returncode
        check("validate | cli rejects an unknown column", rc, 2)

        # ── negate: every query, run inverted ────────────────────────
        #
        # The same QUERIES matrix, complemented. Two properties are
        # checked per case: all three clients agree with the oracle on
        # the complement, and the complement plus the original partition
        # the file exactly — no row in both halves, none lost from both.
        for kind in ("csv", "ndjson", "quoted"):
            path = FIXTURES[kind]
            header = header_of(path)
            for where, columns, limit in QUERIES:
                if where is None or limit is not None:
                    # No filter means the complement is empty (covered by
                    # its own check below); a limit truncates one half so
                    # the partition property no longer holds.
                    continue
                preds = parse_where_for_oracle(where)
                want = oracle_rows(path, header, preds, columns, None, negate=True)
                label = f"{kind} NOT({where!r}) cols={columns}"
                py = via_python(path, where, columns, None, negate=True)
                nd = via_node(path, where, columns, None, negate=True)
                cl = via_cli(path, where, columns, None, negate=True)
                check(f"negate | oracle == python   | {label}", py, want)
                check(f"negate | python == node     | {label}", nd, py)
                check(f"negate | python == cli      | {label}", cl, py)

                kept = via_python(path, where, columns, None)
                total = len(via_python(path, None, columns, None))
                check(f"negate | the two halves partition the file | {label}",
                      len(kept) + len(py), total)

                n_kept = libscanio.count(path, where)
                n_dropped = libscanio.count(path, where, negate=True)
                check(f"negate | count agrees with scan | {label}", n_dropped, len(py))
                check(f"negate | counts partition too | {label}", n_kept + n_dropped, total)

                # scan_array()'s parallel/columnar engine is a different
                # code path from scan()'s row-at-a-time one, so the flag
                # has to be checked there too or it can be honoured by
                # one and dropped by the other.
                arr = libscanio.scan_array(path, where=where, negate=True)
                check(f"negate | scan_array == scan | {label}", len(arr), len(py))

        # No filter: the complement of "keep everything" is empty. Every
        # client has a shortcut path for the no-WHERE case, so each one
        # is a separate chance to answer with the row total instead.
        for kind in ("csv", "ndjson"):
            path = FIXTURES[kind]
            check(f"negate | no filter yields nothing | {kind} python",
                  via_python(path, None, None, None, negate=True), [])
            check(f"negate | no filter yields nothing | {kind} node",
                  via_node(path, None, None, None, negate=True), [])
            check(f"negate | no filter yields nothing | {kind} cli",
                  via_cli(path, None, None, None, negate=True), [])
            check(f"negate | no filter counts zero | {kind}",
                  libscanio.count(path, None, negate=True), 0)

        # Ragged rows: a row too short to test the column cannot satisfy
        # the predicate, so it belongs in the complement — and must not
        # fall out of both halves.
        path = FIXTURES["ragged"]
        for where in ("a = 1", "c = 3"):
            py = via_python(path, where, None, None, negate=True)
            check(f"negate | ragged | oracle == python | {where!r}",
                  py, oracle_rows(path, header_of(path), parse_where_for_oracle(where), negate=True))
            check(f"negate | ragged | python == node | {where!r}",
                  via_node(path, where, None, None, negate=True), py)
            check(f"negate | ragged | python == cli | {where!r}",
                  via_cli(path, where, None, None, negate=True), py)
            check(f"negate | ragged | halves still partition | {where!r}",
                  len(via_python(path, where, None, None)) + len(py), libscanio.count(path))

    print(f"\n{passed}/{passed + failed} differential checks passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
