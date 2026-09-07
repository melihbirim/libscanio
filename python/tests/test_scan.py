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
    r = libscanio.validate(VAL_P, VAL_SCHEMA)
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
          libscanio.validate(VAL_P, {"name": {}}).ok, True)

    # The cap bounds what is STORED, never what is counted — the whole
    # point is that a wholly-broken file still produces a report.
    capped = libscanio.validate(VAL_P, {"id": {"type": "integer"}}, max_errors=0)
    check("validate: max_errors=0 falls back to the default, not to zero errors",
          len(capped.errors), 1)
    r2 = libscanio.validate(VAL_P, VAL_SCHEMA, max_errors=2)
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
                 lambda: libscanio.validate(VAL_P, {"nope": {"required": True}}))
    check_raises("validate: a misspelled rule name is an error too",
                 lambda: libscanio.validate(VAL_P, {"id": {"requred": True}}))
    check_raises("validate_iter: same, before any row is yielded",
                 lambda: list(libscanio.validate_iter(VAL_P, {"nope": {}})))

    inferred = libscanio.infer_schema(VAL_P)
    check("infer_schema: names every column", sorted(inferred), ["amount", "id", "name", "status"])
    check("infer_schema: types what it can, leaves the rest open",
          inferred["amount"], {"type": "integer"})
    check("infer_schema: required=True marks them all",
          libscanio.infer_schema(VAL_P, required=True)["id"], {"required": True})
    check("infer_schema: its own output validates the file it came from",
          libscanio.validate(VAL_P, inferred).ok, True)
finally:
    os.unlink(VAL_P)

# A blank cell is absent, not badly typed — the rule that keeps a report
# about a sparse column readable.
BLANK_P = "_test_validate_blank.csv"
with open(BLANK_P, "w", encoding="utf-8") as f:
    f.write("id,note\n1,\n2,   \n3,hello\n")
try:
    r = libscanio.validate(BLANK_P, {"note": {"type": "integer"}})
    check("validate: blank cells are not type errors", r.errors_total, 1)
    check("validate: ...only the real value is", r.errors[0].value, "hello")
    r = libscanio.validate(BLANK_P, {"note": {"required": True}})
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

print(f"\n{passed}/{total} Python binding tests passed")
sys.exit(0 if passed == total else 1)
