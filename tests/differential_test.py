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
import json
import math
import os
import subprocess
import sys
import tempfile

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


def oracle_rows(path, header, preds, columns=None, limit=None):
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
        if not ok:
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
    """Split a fixture the way libscanio does — NOT the way csv.reader
    does. Quotes are not grouping characters here; see the README's CSV
    note. The oracle has to model the real contract, not the one we might
    wish for."""
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
        for line in lines[1:]:
            yield line.split(",")


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
        return f.readline().rstrip("\n").rstrip("\r").split(",")


# ── the three clients ─────────────────────────────────────────────────


def via_python(path, where, columns, limit):
    kw = {}
    if where:
        kw["where"] = where
    if columns:
        kw["columns"] = columns
    if limit is not None:
        kw["limit"] = limit
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
                           capture_output=True, text=True)
        if p.returncode != 0:
            raise AssertionError(f"node api driver failed: {p.stderr}")
        return json.loads(p.stdout)
    finally:
        os.unlink(driver)


NODE_DRIVER = r"""
const ls = require(process.argv[2]);
const [, , , file, where, columns, limit] = process.argv;
(async () => {
  const opts = {};
  if (where !== '-') opts.where = where;
  if (columns !== '-') opts.columns = columns.split(',');
  if (limit !== '-') opts.limit = Number(limit);
  const rows = [];
  for await (const r of ls.scan(file, opts)) rows.push(r);
  process.stdout.write(JSON.stringify(rows));
})().catch((e) => { process.stderr.write(String(e && e.message)); process.exit(1); });
"""


def via_node(path, where, columns, limit):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(NODE_DRIVER)
        driver = f.name
    try:
        p = subprocess.run(
            ["node", driver, os.path.join(REPO, "node", "index.js"), path,
             where or "-", ",".join(columns) if columns else "-",
             str(limit) if limit is not None else "-"],
            capture_output=True, text=True)
        if p.returncode != 0:
            raise AssertionError(f"node driver failed: {p.stderr}")
        names = columns or header_of(path)
        return [[r.get(n, "") for n in names] for r in json.loads(p.stdout)]
    finally:
        os.unlink(driver)


def via_cli(path, where, columns, limit):
    cmd = [CLI, path, "--format", "ndjson"]
    if where:
        cmd += ["--where", where]
    if columns:
        cmd += ["--columns", ",".join(columns)]
    if limit is not None:
        cmd += ["--limit", str(limit)]
    p = subprocess.run(cmd, capture_output=True, text=True)
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


def main():
    if not os.path.exists(CLI):
        print(f"missing {CLI} — run: zig build cli -Doptimize=ReleaseFast")
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        write_fixtures(tmp)

        for kind in ("csv", "ndjson"):
            path = FIXTURES[kind]
            header = header_of(path)
            for where, columns, limit in QUERIES:
                preds = []
                if where:
                    for part in where.split(" AND "):
                        if " IN " in part:
                            col, rest = part.split(" IN ", 1)
                            vals = [v.strip() for v in rest.strip()[1:-1].split(",")]
                            preds.append((col.strip(), "IN", vals))
                        else:
                            for op in (">=", "<=", "!=", ">", "<", "="):
                                if op in part:
                                    c, v = part.split(op, 1)
                                    preds.append((c.strip(), op, v.strip()))
                                    break
                want = oracle_rows(path, header, preds, columns, limit)
                label = f"{kind} where={where!r} cols={columns} limit={limit}"
                py = via_python(path, where, columns, limit)
                nd = via_node(path, where, columns, limit)
                cl = via_cli(path, where, columns, limit)
                check(f"oracle == python   | {label}", py, want)
                check(f"python == node     | {label}", nd, py)
                check(f"python == cli      | {label}", cl, py)

        # count() must agree with the number of rows the scan returns.
        for kind in ("csv", "ndjson", "ragged"):
            path = FIXTURES[kind]
            for where in (None, "a = 1" if kind == "ragged" else "city = London"):
                n_scan = len(via_python(path, where, None, None))
                n_count = libscanio.count(path, where) if where else libscanio.count(path)
                check(f"count == len(scan) | {kind} where={where!r}", n_count, n_scan)
                cli_cmd = [CLI, path, "--count"] + (["--where", where] if where else [])
                cli_n = int(subprocess.run(cli_cmd, capture_output=True, text=True).stdout.strip())
                check(f"count == cli count | {kind} where={where!r}", cli_n, n_count)

        # The rest of the API surface: aggregate/topk/orderBy/schema are
        # separate code paths in each client (Node re-derives topk/orderBy
        # rows from its own JSON, Python from the C ABI's row buffers), so
        # scan() agreeing proves nothing about them.
        for kind in ("csv", "ndjson"):
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

    print(f"\n{passed}/{passed + failed} differential checks passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
