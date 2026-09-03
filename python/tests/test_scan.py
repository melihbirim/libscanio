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

    check_raises("unknown column in columns raises", lambda: list(libscanio.scan(P, columns=["nope"])))
    check_raises("unknown column in where raises", lambda: list(libscanio.scan(P, where="nope > 5")))
    check_raises("missing file raises", lambda: list(libscanio.scan("/tmp/libscanio_test_does_not_exist.csv")))

    # Repeated scans — same allocator-fault-only-after-repeated-use reasoning as csvql's own test.
    for i in range(200):
        list(libscanio.scan(P, where=f"revenue > {i}"))
    total += 1
    passed += 1
    print("PASS  200 consecutive scans (crosses allocator page boundaries)")
finally:
    os.unlink(P)

print(f"\n{passed}/{total} Python binding tests passed")
sys.exit(0 if passed == total else 1)
