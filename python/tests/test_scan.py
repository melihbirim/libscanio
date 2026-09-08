"""Tests for libscanio's Python binding — the actual dlopen() path via
ctypes, same reasoning as examples/smoke_test.py: passing Zig tests does
not prove the built shared library works for a real consumer.

No pytest dependency: plain asserts, same convention as csvql's own
python/test_csvql.py.
"""

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import libscanio  # noqa: E402

passed = 0
total = 0


def check(label, actual, expected):
    global passed, total
    total += 1
    if actual == expected:
        print(f"PASS  {label}")
        passed += 1
    else:
        print(f"FAIL  {label}\n    expected: {expected!r}\n    actual:   {actual!r}")


def check_raises(label, fn, exc=libscanio.ScanError):
    global passed, total
    total += 1
    try:
        fn()
    except exc:
        print(f"PASS  {label}")
        passed += 1
    except Exception as e:  # noqa: BLE001
        print(f"FAIL  {label}\n    wrong exception: {type(e).__name__}: {e}")
    else:
        print(f"FAIL  {label}\n    no exception raised")


tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False)
tmp.write("customer_id,name,revenue\n1,Alice,500\n2,Bob,1500\n3,Carol,2500\n")
tmp.close()
P = tmp.name

try:
    # The exact target shape from the original ask.
    rows = list(libscanio.scan(P, columns=["customer_id", "revenue"], where="revenue > 1000", limit=100))
    check("filtered+projected+limited scan", rows, [
        {"customer_id": "2", "revenue": "1500"},
        {"customer_id": "3", "revenue": "2500"},
    ])

    check("scan with no options returns all columns, all rows", len(list(libscanio.scan(P))), 3)

    all_rows = list(libscanio.scan(P))
    check("default row shape includes every column", set(all_rows[0].keys()), {"customer_id", "name", "revenue"})

    check("limit alone", len(list(libscanio.scan(P, limit=1))), 1)

    check("AND in where", list(libscanio.scan(P, where="revenue > 1000 AND name = Bob")), [
        {"customer_id": "2", "name": "Bob", "revenue": "1500"},
    ])

    check("IN in where", [r["customer_id"] for r in libscanio.scan(P, where="name IN (Alice, Carol)")], ["1", "3"])
    check("IN composes with AND", [r["customer_id"] for r in libscanio.scan(P, where="name IN (Alice, Carol) AND revenue > 1000")], ["3"])
    check("IN with no matches", list(libscanio.scan(P, where="name IN (Zed, Yolanda)")), [])
    check_raises("IN with no values raises", lambda: list(libscanio.scan(P, where="name IN ()")))

    arr = libscanio.scan_array(P, columns=["customer_id", "revenue"], where="revenue > 1000")
    check("scan_array: tuples, filtered+projected", arr, [("2", "1500"), ("3", "2500")])

    arr_dict = libscanio.scan_array(P, columns=["customer_id", "revenue"], where="revenue > 1000", as_dict=True)
    check("scan_array: as_dict", arr_dict, [
        {"customer_id": "2", "revenue": "1500"},
        {"customer_id": "3", "revenue": "2500"},
    ])

    check("scan_array: no matches returns empty list", libscanio.scan_array(P, where="revenue > 99999"), [])
    check("scan_array: no filter returns every row", len(libscanio.scan_array(P)), 3)

    # Regression test for a real use-after-free: scan()'s open logic used
    # to let the ctypes objects backing WHERE predicates (the encoded
    # value bytes, the predicate array, the options struct) go out of
    # scope and get freed the instant the open helper returned, since
    # nothing kept them referenced for the rest of the generator's life.
    # Zig's Predicate.value is a slice VIEW into that memory, not a copy
    # — reading it after it's freed is undefined behavior. This was
    # invisible on tiny fixtures (freed bytes often aren't overwritten
    # before the next read, by luck) and only showed up reliably at
    # real-file scale, where enough intervening allocator churn corrupts
    # the freed memory before it's read again. Deliberately forcing that
    # same churn here (bytes objects allocated and discarded between
    # every next() call) makes the bug reproduce on a tiny fixture too,
    # instead of depending on scanning a 417MB file to catch it.
    big = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False)
    big.write("id,category\n")
    for i in range(500):
        big.write(f"{i},{'even' if i % 2 == 0 else 'odd'}\n")
    big.close()
    try:
        it = libscanio.scan(big.name, where="category = even")
        results = []
        for _ in range(300):
            churn = [bytes(64) for _ in range(500)]  # force allocator reuse of freed memory
            del churn
            try:
                results.append(next(it))
            except StopIteration:
                break
        check("scan() survives allocator churn between rows (UAF regression)", len(results), 250)
    finally:
        os.unlink(big.name)

    check_raises("unknown column in columns raises", lambda: list(libscanio.scan(P, columns=["nope"])))
    check_raises("unknown column in where raises", lambda: list(libscanio.scan(P, where="nope > 5")))
    check_raises("missing file raises", lambda: list(libscanio.scan("/tmp/libscanio_test_does_not_exist.csv")))

    check("schema returns column names in order", libscanio.schema(P), ["customer_id", "name", "revenue"])

    check("count with no filter", libscanio.count(P), 3)
    check("count with a filter", libscanio.count(P, where="revenue > 1000"), 2)

    agg = libscanio.aggregate(P, "revenue")
    check("aggregate: count", agg["count"], 3)
    check("aggregate: sum", agg["sum"], 4500.0)
    check("aggregate: min", agg["min"], 500.0)
    check("aggregate: max", agg["max"], 2500.0)
    check("aggregate: avg", agg["avg"], 1500.0)

    agg_filtered = libscanio.aggregate(P, "revenue", where="revenue > 1000")
    check("aggregate composes with where", agg_filtered["count"], 2)

    top2 = libscanio.topk(P, "revenue", 2)
    check("topk: 2 highest revenue, best first", [r["customer_id"] for r in top2], ["3", "2"])
    check("topk: includes the sort key", top2[0]["_key"], 2500.0)

    bottom1 = libscanio.topk(P, "revenue", 1, descending=False)
    check("topk: ascending", bottom1[0]["customer_id"], "1")

    ordered_asc = libscanio.order_by(P, "revenue")
    check("order_by: ascending, all rows", [r["customer_id"] for r in ordered_asc], ["1", "2", "3"])

    ordered_desc = libscanio.order_by(P, "revenue", descending=True)
    check("order_by: descending", [r["customer_id"] for r in ordered_desc], ["3", "2", "1"])

    ordered_filtered = libscanio.order_by(P, "revenue", where="revenue > 1000", descending=True)
    check("order_by: composes with where", [r["customer_id"] for r in ordered_filtered], ["3", "2"])

    ordered_empty = libscanio.order_by(P, "revenue", where="revenue > 99999")
    check("order_by: empty result set", ordered_empty, [])

    desc = libscanio.describe(P)
    check(
        "describe: basic types",
        {d["column"]: d["type"] for d in desc},
        {"customer_id": "integer", "name": "string", "revenue": "integer"},
    )

    prof = libscanio.profile(P)
    check("profile: columns", prof["columns"], ["customer_id", "name", "revenue"])
    check("profile: row_count", prof["row_count"], 3)
    check("profile: flags revenue as numeric", "revenue" in prof["numeric_columns"], True)
    check("profile: does not flag name as numeric", "name" in prof["numeric_columns"], False)
    check("profile: numeric column has real aggregate", prof["numeric_columns"]["revenue"]["sum"], 4500.0)

    # Repeated scans — same allocator-fault-only-after-repeated-use reasoning as csvql's own test.
    for i in range(200):
        list(libscanio.scan(P, where=f"revenue > {i}"))
    total += 1
    passed += 1
    print("PASS  200 consecutive scans (crosses allocator page boundaries)")
finally:
    os.unlink(P)


# NDJSON and JSON-array coverage — real gap until now: format inference
# (.ndjson/.jsonl/.json -> the NDJSON scanner, sniffed from content for
# .json specifically) happens at the C ABI level with no format option
# exposed to Python at all, so this was "should work, per the Zig-level
# tests" rather than actually verified through ctypes/dlopen(). Same
# fixture shape as the CSV tests above, for direct comparison.
ndjson_tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".ndjson", delete=False)
ndjson_tmp.write(
    '{"customer_id":"1","name":"Alice","revenue":"500"}\n'
    '{"customer_id":"2","name":"Bob","revenue":"1500"}\n'
    '{"customer_id":"3","name":"Carol","revenue":"2500"}\n'
)
ndjson_tmp.close()
ND = ndjson_tmp.name

json_array_tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
json_array_tmp.write(
    '[{"customer_id":"1","name":"Alice","revenue":"500"},'
    '{"customer_id":"2","name":"Bob","revenue":"1500"},'
    '{"customer_id":"3","name":"Carol","revenue":"2500"}]'
)
json_array_tmp.close()
JA = json_array_tmp.name

try:
    check("ndjson: schema", libscanio.schema(ND), ["customer_id", "name", "revenue"])
    check("ndjson: count with no filter", libscanio.count(ND), 3)
    check("ndjson: scan with filter", list(libscanio.scan(ND, where="revenue > 1000")), [
        {"customer_id": "2", "name": "Bob", "revenue": "1500"},
        {"customer_id": "3", "name": "Carol", "revenue": "2500"},
    ])
    check(
        "ndjson: scan_array projected",
        libscanio.scan_array(ND, columns=["customer_id", "revenue"], where="revenue > 1000"),
        [("2", "1500"), ("3", "2500")],
    )
    agg_nd = libscanio.aggregate(ND, "revenue")
    check("ndjson: aggregate sum", agg_nd["sum"], 4500.0)

    check("json array: schema", libscanio.schema(JA), ["customer_id", "name", "revenue"])
    check("json array: count with no filter", libscanio.count(JA), 3)
    check("json array: scan with filter", list(libscanio.scan(JA, where="revenue > 1000")), [
        {"customer_id": "2", "name": "Bob", "revenue": "1500"},
        {"customer_id": "3", "name": "Carol", "revenue": "2500"},
    ])
    check(
        "json array: scan_array projected",
        libscanio.scan_array(JA, columns=["customer_id", "revenue"], where="revenue > 1000"),
        [("2", "1500"), ("3", "2500")],
    )
    agg_ja = libscanio.aggregate(JA, "revenue")
    check("json array: aggregate sum", agg_ja["sum"], 4500.0)
finally:
    os.unlink(ND)
    os.unlink(JA)


# describe(): dedicated fixture covering every type category, not just
# the integer/string columns the CSV fixture above happens to have.
describe_tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False)
describe_tmp.write(
    "id,price,active,created_at,notes\n"
    "1,19.99,true,2023-05-26T22:00:00Z,\n"
    "2,29.50,false,2023-06-01T10:15:30Z,\n"
    "3,9.75,true,2023-07-04T00:00:00Z,\n"
)
describe_tmp.close()
DESC_P = describe_tmp.name
try:
    desc_full = {d["column"]: d["type"] for d in libscanio.describe(DESC_P)}
    check(
        "describe: float/boolean/datetime/empty",
        desc_full,
        {"id": "integer", "price": "float", "active": "boolean", "created_at": "datetime", "notes": "empty"},
    )
finally:
    os.unlink(DESC_P)

alnum_tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False)
alnum_tmp.write("order_id,amount\nORD001,50\nORD002,1500\n")
alnum_tmp.close()
ALNUM_P = alnum_tmp.name
try:
    check(
        "describe: alphanumeric ID column stays string, not integer",
        {d["column"]: d["type"] for d in libscanio.describe(ALNUM_P)},
        {"order_id": "string", "amount": "integer"},
    )
finally:
    os.unlink(ALNUM_P)


# scan_table(): same describe()-fixture shape, but checking the actual
# typed Arrow output, not just the type label. Reuses the two real ISO8601
# shapes describe() lumps under one "datetime" label (trailing Z needs a
# tz-aware Arrow target, bare needs tz-naive) to make sure both cast paths
# work, not just one.
st_tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False)
st_tmp.write(
    "id,price,active,created_at,notes\n"
    "1,19.99,true,2023-05-26T22:00:00Z,\n"
    "2,29.50,false,2023-06-01T10:15:30Z,\n"
    "3,9.75,true,2023-07-04T00:00:00Z,\n"
)
st_tmp.close()
ST_P = st_tmp.name
try:
    tbl = libscanio.scan_table(ST_P, infer_types=True)
    check(
        "scan_table: infer_types=True casts to typed columns",
        {name: str(tbl.schema.field(name).type) for name in tbl.column_names},
        {
            "id": "int64",
            "price": "double",
            "active": "bool",
            "created_at": "timestamp[s, tz=UTC]",
            "notes": "string",
        },
    )
    check("scan_table: typed values round-trip correctly", tbl.column("price").to_pylist(), [19.99, 29.5, 9.75])
    check("scan_table: boolean values correct", tbl.column("active").to_pylist(), [True, False, True])

    tbl_untyped = libscanio.scan_table(ST_P, infer_types=False)
    check(
        "scan_table: infer_types=False keeps every column a string",
        {str(f.type) for f in tbl_untyped.schema},
        {"string"},
    )
finally:
    os.unlink(ST_P)

# describe()'s sample-based inference can be wrong for data outside the
# sample — scan_table() must fall back to a string column for THAT one
# column instead of raising, since the real value pyarrow can't cast
# only shows up after the sample describe() actually looked at.
st_bad_tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False)
lines = ["id,mixed\n"] + [f"{i},{i}\n" for i in range(1, 1001)] + ["1001,not-a-number\n"]
st_bad_tmp.writelines(lines)
st_bad_tmp.close()
ST_BAD_P = st_bad_tmp.name
try:
    check(
        "scan_table: describe() sample misses the later non-numeric value",
        {d["column"]: d["type"] for d in libscanio.describe(ST_BAD_P)}["mixed"],
        "integer",
    )
    tbl_bad = libscanio.scan_table(ST_BAD_P, infer_types=True)
    check(
        "scan_table: cast failure falls back to string instead of raising",
        str(tbl_bad.schema.field("mixed").type),
        "string",
    )
    check("scan_table: fallback column still has correct, complete data", tbl_bad.column("mixed").to_pylist()[-1], "not-a-number")
finally:
    os.unlink(ST_BAD_P)

# ---------------------------------------------------------------------
# scan_table(infer_types=True) picks the datetime target from a short
# probe rather than trying each on the whole column. Both ISO8601 shapes
# describe() labels "datetime" must still land on the right Arrow type,
# and a column the probe agrees with but the full data doesn't must
# still fall back to string rather than half-cast.
ST_DT_P = "_test_scan_table_datetime.csv"
with open(ST_DT_P, "w") as f:
    f.write("id,naive,aware\n")
    for i in range(12):
        f.write(f"{i},2024-01-0{i % 9 + 1}T08:00:00,2024-01-0{i % 9 + 1}T08:00:00Z\n")
try:
    tbl_dt = libscanio.scan_table(ST_DT_P, infer_types=True)
    check("scan_table: bare ISO8601 casts to a tz-naive timestamp",
          str(tbl_dt.schema.field("naive").type), "timestamp[s]")
    check("scan_table: ...Z ISO8601 casts to a tz-aware timestamp",
          str(tbl_dt.schema.field("aware").type), "timestamp[s, tz=UTC]")
    check("scan_table: datetime values round-trip",
          str(tbl_dt.column("naive")[0]), "2024-01-01 08:00:00")
finally:
    os.unlink(ST_DT_P)

# The probe sees only well-formed timestamps; a bad value later in the
# column must still leave the whole column a string.
ST_DTBAD_P = "_test_scan_table_datetime_mixed.csv"
with open(ST_DTBAD_P, "w") as f:
    f.write("id,when\n")
    for i in range(12):
        f.write(f"{i},2024-01-01T08:00:00Z\n")
    f.write("99,not-a-date\n")
try:
    tbl_dtbad = libscanio.scan_table(ST_DTBAD_P, infer_types=True)
    check("scan_table: datetime probe agreeing but full column failing keeps string",
          str(tbl_dtbad.schema.field("when").type), "string")
    check("scan_table: that column keeps its complete data",
          tbl_dtbad.column("when").to_pylist()[-1], "not-a-date")
finally:
    os.unlink(ST_DTBAD_P)

# ---------------------------------------------------------------------
# A row with MORE fields than the header used to raise IndexError out of
# scan(), killing the iteration. Real files hit this. Extra fields get a
# positional colN key, which is
# what the Node client and the scanio CLI emit for the same row.
RAGGED_P = "_test_ragged.csv"
with open(RAGGED_P, "w") as f:
    f.write("id,name,city\n1,Smith,London,EXTRA\n2,Alice,Paris\n3,Bo\n")
try:
    rows = list(libscanio.scan(RAGGED_P))
    check("scan: a row longer than the header does not raise", len(rows), 3)
    check("scan: the extra field is kept under a positional key", rows[0].get("col3"), "EXTRA")
    check("scan: header columns of that row are still correct",
          [rows[0]["id"], rows[0]["name"], rows[0]["city"]], ["1", "Smith", "London"])
    check("scan: a row shorter than the header just omits the missing key",
          sorted(rows[2].keys()), ["id", "name"])
    check("scan: normal rows are untouched", rows[1], {"id": "2", "name": "Alice", "city": "Paris"})

    arr = libscanio.scan_array(RAGGED_P, as_dict=True)
    check("scan_array(as_dict): ragged row does not raise", len(arr), 3)
    check("scan_array(as_dict): header columns still correct", arr[0]["city"], "London")

    check("count: unaffected by ragged rows", libscanio.count(RAGGED_P), 3)
    check("order_by: ragged row does not raise",
          len(libscanio.order_by(RAGGED_P, "id")), 3)
finally:
    os.unlink(RAGGED_P)

# RFC 4180 quoting. The header goes through the same splitter as every
# other row, so a quoted column name has to come back unquoted too.
QUOTED_P = "_test_quoted.csv"
with open(QUOTED_P, "w", encoding="utf-8") as f:
    f.write('id,"name",city\n')
    f.write('1,"Smith, John",London\n')
    f.write('2,"He said ""hi""",Paris\n')
    f.write('3,he said "hi",Berlin\n')
try:
    check("quoted CSV: header quoting is stripped", libscanio.schema(QUOTED_P), ["id", "name", "city"])
    rows = list(libscanio.scan(QUOTED_P))
    check("quoted CSV: a delimiter inside quotes does not split the field", rows, [
        {"id": "1", "name": "Smith, John", "city": "London"},
        {"id": "2", "name": 'He said "hi"', "city": "Paris"},
        {"id": "3", "name": 'he said "hi"', "city": "Berlin"},
    ])
    check("quoted CSV: scan_array agrees with scan",
          libscanio.scan_array(QUOTED_P),
          [("1", "Smith, John", "London"), ("2", 'He said "hi"', "Paris"), ("3", 'he said "hi"', "Berlin")])
    check("quoted CSV: a quoted value is filterable by its real content",
          len(list(libscanio.scan(QUOTED_P, where="name = Smith, John"))), 1)
    # The parallel/columnar path is a different splitter call site than
    # scan()'s, so Arrow output gets its own check.
    try:
        t = libscanio.scan_table(QUOTED_P)
        check("quoted CSV: scan_table (zero-copy Arrow) agrees",
              t.column("name").to_pylist(), ["Smith, John", 'He said "hi"', 'he said "hi"'])
    except ImportError:
        pass  # pyarrow not installed
finally:
    os.unlink(QUOTED_P)

# The one shape this reader cannot represent: a record spanning lines.
# Every entry point must say so rather than hand back a torn row.
BADQ_P = "_test_badquote.csv"
with open(BADQ_P, "w", encoding="utf-8") as f:
    f.write('a,b\n1,"oops\n')
try:
    check_raises("unterminated quote: scan reports it", lambda: list(libscanio.scan(BADQ_P)))
    check_raises("unterminated quote: scan_array reports it", lambda: libscanio.scan_array(BADQ_P))
    check_raises("unterminated quote: aggregate reports it", lambda: libscanio.aggregate(BADQ_P, "b"))
    check_raises("unterminated quote: topk reports it", lambda: libscanio.topk(BADQ_P, "b", 2))
    check_raises("unterminated quote: order_by reports it", lambda: libscanio.order_by(BADQ_P, "b"))
    check_raises("unterminated quote: describe reports it", lambda: libscanio.describe(BADQ_P))
finally:
    os.unlink(BADQ_P)

# ---------------------------------------------------------------------
# Import validation. The rules live in Zig, so these tests are also the
# Python client's half of the promise that Node gets the same answers —
# tests/differential_test.py checks the two against each other directly.
VAL_P = "_test_validate.csv"
with open(VAL_P, "w", encoding="utf-8") as f:
    f.write("id,name,amount,status\n")
    f.write("1,Alice,100,new\n")
    f.write("x,Bob,-5,bogus\n")
    f.write("3,,20,paid\n")
VAL_SCHEMA = {
    "id": {"type": "integer", "required": True},
    "name": {"required": True},
    "amount": {"type": "float", "min": 0},
    "status": {"one_of": ["new", "paid", "shipped"]},
}
try:
    r = libscanio.validate_report(VAL_P, VAL_SCHEMA)
    check("validate: row totals", (r.rows_total, r.rows_valid, r.rows_invalid), (3, 1, 2))
    check("validate: ok is False when any row failed", r.ok, False)
    check("validate: every failure is counted", r.errors_total, 4)
    check("validate: counts are keyed by rule name",
          r.counts, {"bad_type": 1, "below_min": 1, "not_in_set": 1, "missing_required": 1})
    check("validate: an error names the row, column and offending value",
          (r.errors[0].row, r.errors[0].column, r.errors[0].column_name,
           r.errors[0].rule, r.errors[0].value),
          (2, 0, "id", "bad_type", "x"))
    check("validate: a clean run reports ok",
          libscanio.validate_report(VAL_P, {"name": {}}).ok, True)

    # The cap bounds what is STORED, never what is counted — the whole
    # point is that a wholly-broken file still produces a report.
    capped = libscanio.validate_report(VAL_P, {"id": {"type": "integer"}}, max_errors=0)
    check("validate: max_errors=0 falls back to the default, not to zero errors",
          len(capped.errors), 1)
    r2 = libscanio.validate_report(VAL_P, VAL_SCHEMA, max_errors=2)
    check("validate: max_errors caps the stored list", len(r2.errors), 2)
    check("validate: ...but not the totals", r2.errors_total, 4)
    check("validate: ...and says so", r2.truncated, True)

    # validate_iter is the streaming half: the row AND its reasons, so an
    # importer can write both sides in one pass.
    seen = list(libscanio.validate_iter(VAL_P, VAL_SCHEMA))
    check("validate_iter: yields every row, not just the bad ones", len(seen), 3)
    check("validate_iter: a passing row carries no errors", seen[0][1], [])
    check("validate_iter: a failing row carries the row itself",
          seen[1][0], {"id": "x", "name": "Bob", "amount": "-5", "status": "bogus"})
    check("validate_iter: ...and every rule it broke",
          sorted(e.rule for e in seen[1][1]), ["bad_type", "below_min", "not_in_set"])
    check("validate_iter: agrees with validate on which rows are clean",
          sum(1 for _, errs in seen if not errs), r.rows_valid)

    check_raises("validate: an unknown column is an error, not an unenforced rule",
                 lambda: libscanio.validate_report(VAL_P, {"nope": {"required": True}}))
    check_raises("validate: a misspelled rule name is an error too",
                 lambda: libscanio.validate_report(VAL_P, {"id": {"requred": True}}))
    check_raises("validate_iter: same, before any row is yielded",
                 lambda: list(libscanio.validate_iter(VAL_P, {"nope": {}})))

    inferred = libscanio.infer_schema(VAL_P)
    check("infer_schema: names every column", sorted(inferred), ["amount", "id", "name", "status"])
    check("infer_schema: types what it can, leaves the rest open",
          inferred["amount"], {"type": "integer"})
    check("infer_schema: required=True marks them all",
          libscanio.infer_schema(VAL_P, required=True)["id"], {"required": True})
    check("infer_schema: its own output validates the file it came from",
          libscanio.validate_report(VAL_P, inferred).ok, True)
finally:
    os.unlink(VAL_P)

# A blank cell is absent, not badly typed — the rule that keeps a report
# about a sparse column readable.
BLANK_P = "_test_validate_blank.csv"
with open(BLANK_P, "w", encoding="utf-8") as f:
    f.write("id,note\n1,\n2,   \n3,hello\n")
try:
    r = libscanio.validate_report(BLANK_P, {"note": {"type": "integer"}})
    check("validate: blank cells are not type errors", r.errors_total, 1)
    check("validate: ...only the real value is", r.errors[0].value, "hello")
    r = libscanio.validate_report(BLANK_P, {"note": {"required": True}})
    check("validate: required treats a whitespace-only cell as blank", r.errors_total, 2)
finally:
    os.unlink(BLANK_P)

# ---------------------------------------------------------------------
# negate: the complement of a WHERE clause. The property that matters is
# that the two halves PARTITION the file — every row in exactly one, no
# row in both, none lost.
NEG_P = "_test_negate.csv"
with open(NEG_P, "w", encoding="utf-8") as f:
    f.write("id,city,amount\n1,London,10\n2,Paris,20\n3,London,30\n4,Berlin,40\n5,Paris,50\n")
try:
    kept = libscanio.scan_array(NEG_P, where="city = London")
    dropped = libscanio.scan_array(NEG_P, where="city = London", negate=True)
    check("negate: scan_array returns the complement", len(dropped), 3)
    check("negate: the two halves partition the file",
          len(kept) + len(dropped), libscanio.count(NEG_P))
    check("negate: no row appears in both halves",
          set(r[0] for r in kept) & set(r[0] for r in dropped), set())
    check("negate: count agrees with scan_array",
          libscanio.count(NEG_P, "city = London", negate=True), len(dropped))
    check("negate: scan() streams the same rows scan_array() collects",
          [tuple(r.values()) for r in libscanio.scan(NEG_P, where="city = London", negate=True)],
          [tuple(r) for r in dropped])

    # NOT(a AND b) is the negation of the CONJUNCTION, not of each clause —
    # a row failing either half belongs in the complement.
    both = libscanio.scan_array(NEG_P, where="city = London AND amount > 20")
    neither = libscanio.scan_array(NEG_P, where="city = London AND amount > 20", negate=True)
    check("negate: inverts the whole AND-list, not each clause", len(both), 1)
    check("negate: ...so everything else is rejected", len(neither), 4)

    check("negate: with no where, nothing matches", libscanio.count(NEG_P, negate=True), 0)
    check("negate: ...and scan yields nothing", list(libscanio.scan(NEG_P, negate=True)), [])
    check("negate: composes with columns and limit",
          libscanio.scan_array(NEG_P, columns=["city"], where="city = London",
                               limit=2, negate=True),
          [("Paris",), ("Berlin",)])
    try:
        import pyarrow  # noqa: F401
        check("negate: scan_table (zero-copy Arrow) returns the same complement",
              libscanio.scan_table(NEG_P, where="city = London", negate=True).num_rows, 3)
    except ImportError:
        pass
finally:
    os.unlink(NEG_P)

# A row too short to test the column cannot satisfy the predicate, so it
# belongs with the rejects — the answer an import wants.
NEG_R = "_test_negate_ragged.csv"
with open(NEG_R, "w", encoding="utf-8") as f:
    f.write("a,b\n1,10\n2\n3,30\n")
try:
    check("negate: a truncated row counts as rejected",
          libscanio.count(NEG_R, "b >= 0", negate=True), 1)
    check("negate: ...and is not lost from the partition",
          libscanio.count(NEG_R, "b >= 0") + libscanio.count(NEG_R, "b >= 0", negate=True),
          libscanio.count(NEG_R))
finally:
    os.unlink(NEG_R)


# Batch transport: compare complete values/errors, not only row counts.
import tempfile
import json
with tempfile.TemporaryDirectory() as batch_tmp:
    for fmt in ("csv", "ndjson", "json"):
        bp = os.path.join(batch_tmp, "rows." + fmt)
        records = [{"a": "1", "b": "Zürich"}, {"a": "bad", "b": 'quote"'},
                   {"a": "3", "b": "tail"}, {"a": "4", "b": "last"}]
        with open(bp, "w", encoding="utf-8", newline="") as f:
            if fmt == "csv":
                import csv
                writer = csv.writer(f); writer.writerow(["a", "b"])
                writer.writerows([r["a"], r["b"]] for r in records)
            elif fmt == "ndjson":
                f.write("\n".join(json.dumps(r) for r in records))
            else:
                json.dump(records, f)
        rules = {"a": {"type": "integer", "min": 2}}
        expected = list(libscanio.scan(bp))
        errors = list(libscanio.validate_iter(bp, rules))
        for size in (1, 2, 3, 8192):
            batches = list(libscanio.scan_batches(bp, batch_size=size))
            check(f"{fmt} batches {size}: values/order/retention", [r for b in batches for r in b], expected)
            check(f"{fmt} batches {size}: size bound", all(0 < len(b) <= size for b in batches), True)
            check(f"{fmt} validation batches {size}: full errors",
                  [r for b in libscanio.validate_batches(bp, rules, batch_size=size) for r in b], errors)
        check(f"{fmt} batches: projection/filter/limit/negate",
              [r for b in libscanio.scan_batches(bp, columns=["b"], where="a = 1", negate=True, limit=2) for r in b],
              list(libscanio.scan(bp, columns=["b"], where="a = 1", negate=True, limit=2)))
        check(f"{fmt} batches: byte target", [len(b) for b in libscanio.scan_batches(bp, target_bytes=1)], [1]*4)
        check(f"{fmt} batches: tuple output", [r for b in libscanio.scan_batches(bp, as_dict=False) for r in b],
              [tuple(r.values()) for r in expected])
        check(f"{fmt} batches: empty selection", list(libscanio.scan_batches(bp, where="a = absent")), [])
        for _ in range(10):
            it = libscanio.validate_batches(bp, rules, batch_size=1)
            next(it); it.close()
        for kwargs in ({"batch_size": 0}, {"batch_size": 65537}, {"batch_size": True}, {"target_bytes": 0}):
            check_raises(f"{fmt} invalid batch options {kwargs}", lambda kw=kwargs: list(libscanio.scan_batches(bp, **kw)), ValueError)
    bp = os.path.join(batch_tmp, "ragged.csv")
    with open(bp, "w") as f: f.write("a,b\n1,2,extra\n3\n")
    check("batches: ragged rows", [r for b in libscanio.scan_batches(bp) for r in b], list(libscanio.scan(bp)))
    check("validation batches: ragged errors", [r for b in libscanio.validate_batches(bp, {}) for r in b], list(libscanio.validate_iter(bp, {})))
    with open(bp, "w") as f: f.write('a,b\n1,good\n2,"unterminated\n')
    it = libscanio.scan_batches(bp, batch_size=1)
    check("batches: valid batch before malformed row", next(it), [{"a":"1", "b":"good"}])
    check_raises("batches: malformed row raises", lambda: next(it))
    with open(bp, "w") as f: f.write('a,b\n1,nul\x00tail\n')
    check("batches: embedded NUL preserved", next(libscanio.scan_batches(bp))[0]["b"], "nul\x00tail")


# Native routing preserves every parsed value and error, and never overwrites.
with tempfile.TemporaryDirectory() as tmp_import:
    import csv
    import io
    import json
    source = Path(tmp_import) / 'input.csv'
    good = Path(tmp_import) / 'good.csv'
    bad = Path(tmp_import) / 'bad.jsonl'
    records = [['1', 'Zürich'], ['bad', 'quote"'], ['3', 'comma,value']]
    rules = {'a': {'type': 'integer', 'min': 2}}
    for fmt in ('csv', 'ndjson', 'json'):
        source = Path(tmp_import) / ('input.' + fmt)
        objects = [dict(zip(['a', 'b'], row)) for row in records]
        if fmt == 'csv':
            with open(source, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f); writer.writerow(['a', 'b']); writer.writerows(records)
        else:
            source.write_text(json.dumps(objects) if fmt == 'json' else '\n'.join(map(json.dumps, objects)), encoding='utf-8')
        expected_good = io.StringIO(newline='')
        writer = csv.writer(expected_good); writer.writerow(['a','b'])
        expected_bad = []
        for row, errors in libscanio.validate_iter(str(source), rules):
            values = list(row.values())
            if errors:
                expected_bad.append(json.dumps({'values':values,'errors':[e.as_dict() for e in errors]}, ensure_ascii=False, separators=(',', ':'))+'\n')
            else: writer.writerow(values)
        stats = libscanio.validate_to_files(str(source), rules, str(good), str(bad))
        check(f'{fmt} native import totals', stats, dict(rows_total=3,rows_valid=1,rows_invalid=2,errors_total=2))
        check(f'{fmt} native import accepted bytes', good.read_bytes(), expected_good.getvalue().encode())
        check(f'{fmt} native import rejected bytes', bad.read_bytes(), ''.join(expected_bad).encode())
        good.unlink(); bad.unlink()
    source = Path(tmp_import) / 'input.csv'
    source.write_text('a,b\n1,2,extra\n3\n', encoding='utf-8')
    stats = libscanio.validate_to_files(str(source), {}, str(good), str(bad))
    check('native import retains ragged fields', [json.loads(line)['values'] for line in bad.read_text().splitlines()], [['1','2','extra'],['3']])
    good.unlink(); bad.unlink()
    source.write_text('v\n\n', encoding='utf-8')
    libscanio.validate_to_files(str(source), {}, str(good), str(bad))
    check('native import single empty field CSV', good.read_bytes(), b'v\r\n""\r\n')
    good.unlink(); bad.unlink()
    source.write_text('a,a\n1,2\n', encoding='utf-8')
    libscanio.validate_to_files(str(source), {'a':{'min':5}}, str(good), str(bad))
    check('native import duplicate names retain both values', json.loads(bad.read_text())['values'], ['1','2'])
    good.unlink(); bad.unlink()
    original = source.read_bytes()
    check_raises('native import refuses source overwrite', lambda: libscanio.validate_to_files(str(source), {}, str(source), str(bad)))
    check('native import input untouched', source.read_bytes(), original)
    bad.write_text('keep')
    check_raises('native import refuses existing rejection file', lambda: libscanio.validate_to_files(str(source), {}, str(good), str(bad)))
    check('native import existing output untouched', bad.read_text(), 'keep')
    check('native import removes first output if second open fails', good.exists(), False)
    bad.unlink()
    check_raises('native import identical outputs', lambda: libscanio.validate_to_files(str(source), {}, str(good), str(good)))
    check('native import identical output cleanup', good.exists(), False)
    for data in (b'a,b\n1,ok\n2,"unterminated\n', b'a\n\xff\n'):
        source.write_bytes(data)
        check_raises('native import malformed input', lambda: libscanio.validate_to_files(str(source), {}, str(good), str(bad)))
        check('native import removes partial outputs', (good.exists(),bad.exists()), (False,False))


# Uploaded-byte validation: no output files and only failures cross the ABI.
rules = {"a": {"type": "integer", "required": True}}
for fmt, valid, invalid in [
    ("csv", b"a,b\n1,ok\n2,yes\n", b"a,b\n1,ok\nbad,no\nwrong,yes\n"),
    ("ndjson", b'{"a":1,"b":"ok"}\n', b'{"a":1,"b":"ok"}\n{"a":"bad","b":"no"}\n{"a":"wrong","b":"yes"}\n'),
    ("json", b'[{"a":1,"b":"ok"}]', b'[{"a":1,"b":"ok"},{"a":"bad","b":"no"},{"a":"wrong","b":"yes"}]'),
]:
    check(f'{fmt} fast valid bool', libscanio.validate(valid, rules, format=fmt) is True, True)
    check(f'{fmt} fast invalid bool', libscanio.validate(invalid, rules, format=fmt) is False, True)
    check(f'{fmt} full valid empty', libscanio.validate(valid, rules, mode='full', format=fmt), [])
    failed = libscanio.validate(invalid, rules, mode='full', format=fmt)
    check(f'{fmt} full every failure', [r['values'] for r in failed], [['bad','no'],['wrong','yes']])
    check(f'{fmt} error has no row number', 'row' in failed[0]['errors'][0], False)
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / ('input.' + fmt)
        p.write_bytes(invalid)
        check(f'{fmt} path parity', libscanio.validate(p, rules, mode='full'), failed)

check('default input format CSV', libscanio.validate(b'a\n1\n', rules), True)
check('header only valid', libscanio.validate(b'a\n', rules), True)
check('full has no failure cap', len(libscanio.validate(b'a\n' + b'bad\n' * 250, rules, mode='full')), 250)
check('fast stops before malformed tail', libscanio.validate(b'a\nbad\n"unterminated', rules), False)
check_raises('full sees malformed tail', lambda: libscanio.validate(b'a\nbad\n"unterminated', rules, mode='full'))
check_raises('fast sees malformed first record', lambda: libscanio.validate(b'a\n"unterminated', rules))
check_raises('empty bytes raise', lambda: libscanio.validate(b'', {}))
check_raises('unknown schema column', lambda: libscanio.validate(b'a\n1\n', {'missing': {}}))
check_raises('bad mode', lambda: libscanio.validate(b'a\n', {}, mode='slow'), ValueError)
check_raises('bad format', lambda: libscanio.validate(b'a\n', {}, format='xml'), ValueError)
check_raises('bad UTF8 even without rules', lambda: libscanio.validate(b'a\n\xff\n', {}))
check('NUL and unicode preserved', libscanio.validate('a\n"é\x00"\n'.encode(), rules, mode='full')[0]['values'], ['é\x00'])
check('ragged fields retained', libscanio.validate(b'a\n1,extra\n', {}, mode='full')[0]['values'], ['1','extra'])
check('duplicate headers retained', libscanio.validate(b'a,a\nbad,2\n', rules, mode='full')[0]['values'], ['bad','2'])
check('large record crosses buffers', libscanio.validate(b'a\n' + b'x' * 200000 + b'\n', rules, mode='full')[0]['values'], ['x' * 200000])


# CPython extension vs the retained C JSON bridge: exact result contracts.
from libscanio import _native, _loader
import ctypes
check('CPython core is ReleaseFast', _native.build_mode(), 'ReleaseFast')
for payload, fmt in [(b'a,b\n1,ok\n-2,\nbad,x\n5,too-long\n1,ok,extra\n', 1),
                     (b'[{"a":1,"b":"ok"},{"a":-2,"b":""},{"a":"bad","b":"x"}]', 2)]:
    sch = {'a': {'type':'integer', 'min':0}, 'b': {'required':True, 'min_len':2, 'max_len':3}}
    lib = _loader.load()
    for full in [False, True]:
        ptr = lib.scanio_validate_outcome(payload, len(payload), json.dumps(sch).encode(), fmt, full)
        if not ptr: raise AssertionError('JSON reference failed')
        try: expected = json.loads(ctypes.string_at(ptr))
        finally: lib.scanio_outcome_free(ptr)
        actual = _native.validate(payload, json.dumps(sch).encode(), fmt, full)
        check(f'CPython/JSON parity format={fmt} full={full}', actual, expected)
        if full:
            original = json.loads(json.dumps(actual))
            for _ in range(100): _native.validate(payload, json.dumps(sch).encode(), fmt, True)
            check('CPython retained output owns its strings', actual, original)
            actual[0]['errors'][0]['rule'] = 'edited'
            check('CPython failures are independent', actual[1:], original[1:])
check_raises('CPython raw input type', lambda: _native.validate('a', b'{}', 1, 0), TypeError)
check_raises('CPython raw format', lambda: _native.validate(b'a', b'{}', 3, 0), ValueError)
check_raises('CPython raw mode', lambda: _native.validate(b'a', b'{}', 1, 2), ValueError)
for _ in range(100):
    try: libscanio.validate(b'a\nbad\n"unfinished', rules, mode='full')
    except libscanio.ScanError: pass
    else: raise AssertionError('malformed tail accepted')
check('CPython usable after partial-result failures', libscanio.validate(b'a\n1\n', rules), True)


# A long native scan must remain interruptible while holding the GIL.
import signal
if hasattr(signal, 'setitimer'):
    payload = b'a\n' + b'1\n' * 2000000
    previous = signal.getsignal(signal.SIGALRM)
    def interrupt_validation(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGALRM, interrupt_validation)
    try:
        signal.setitimer(signal.ITIMER_REAL, 0.001)
        check_raises('CPython long scan handles signals', lambda: libscanio.validate(payload, rules), KeyboardInterrupt)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


# Containers must participate in GC once published to mutable Python callers.
import gc
import weakref
class CycleMarker:
    pass
result = libscanio.validate(b'a\nbad\n', rules, mode='full')
check('CPython published containers are GC tracked',
      all(gc.is_tracked(x) for x in [result, result[0], result[0]['values'], result[0]['errors']]), True)
marker = CycleMarker()
reference = weakref.ref(marker)
result[0]['values'].extend([marker, result])
result[0]['errors'].append(result)
del marker, result
gc.collect()
check('CPython caller-created cycles are collected', reference() is None, True)

print(f"\n{passed}/{total} Python binding tests passed")
sys.exit(0 if passed == total else 1)
