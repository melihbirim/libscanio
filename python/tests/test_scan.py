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

print(f"\n{passed}/{total} Python binding tests passed")
sys.exit(0 if passed == total else 1)
