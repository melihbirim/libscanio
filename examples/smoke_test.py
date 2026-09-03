"""dlopen() smoke test for libscanio's C ABI.

Zig's own `zig build test` runs in-process — it never dlopen()s the
built shared library the way a real host (Python ctypes, Node N-API)
does. That gap is exactly what let csvql's #149 (a native-binding crash)
ship: the library compiled and its own tests passed, but it aborted the
first time a real host process dlopen()'d it. This script is the
equivalent check for libscanio: does the .dylib/.so actually work when
loaded the way a real consumer loads it, not just when compiled?

Usage: python3 examples/smoke_test.py [path/to/libscanio.dylib]
"""

import ctypes
import os
import sys
import tempfile

def _default_lib_path():
    here = os.path.dirname(__file__)
    if sys.platform == "win32":
        # The loadable .dll lands in zig-out/bin on Windows, not
        # zig-out/lib (which only gets the .lib import stub) — real bug
        # found running this in CI: this used to fall through to the
        # "else" branch below and look for a nonexistent libscanio.so.
        return os.path.join(here, "..", "zig-out", "bin", "scanio.dll")
    if sys.platform == "darwin":
        return os.path.join(here, "..", "zig-out", "lib", "libscanio.dylib")
    return os.path.join(here, "..", "zig-out", "lib", "libscanio.so")


lib_path = sys.argv[1] if len(sys.argv) > 1 else _default_lib_path()

lib = ctypes.CDLL(lib_path)

lib.scanio_open.restype = ctypes.c_void_p
lib.scanio_open.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
lib.scanio_next.restype = ctypes.c_int
lib.scanio_next.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)), ctypes.POINTER(ctypes.c_size_t)]
lib.scanio_count.restype = ctypes.c_int64
lib.scanio_count.argtypes = [ctypes.c_void_p]
lib.scanio_close.argtypes = [ctypes.c_void_p]
lib.scanio_last_error.restype = ctypes.c_char_p

tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False)
tmp.write("id,amount\n1,50\n2,1500\n3,2500\n")
tmp.close()

passed = 0
total = 0


def check(label, cond):
    global passed, total
    total += 1
    if cond:
        print(f"PASS  {label}")
        passed += 1
    else:
        print(f"FAIL  {label}")


try:
    ctx = lib.scanio_open(tmp.name.encode(), None)
    check("scanio_open returns a non-null handle", ctx is not None and ctx != 0)

    fields = ctypes.POINTER(ctypes.c_char_p)()
    n = ctypes.c_size_t()

    rc = lib.scanio_next(ctx, ctypes.byref(fields), ctypes.byref(n))
    check("first scanio_next returns 1 (a row)", rc == 1)
    check("first row has 2 fields", n.value == 2)
    check("first row field 0 == '1'", fields[0] == b"1")
    check("first row field 1 == '50'", fields[1] == b"50")

    rc = lib.scanio_next(ctx, ctypes.byref(fields), ctypes.byref(n))
    check("second row field 0 == '2'", fields[0] == b"2")

    lib.scanio_close(ctx)

    # A second open/close cycle on the same process — the #149 class of
    # bug in csvql only appeared after repeated allocator use, not once.
    ctx2 = lib.scanio_open(tmp.name.encode(), None)
    count = lib.scanio_count(ctx2)
    check("scanio_count == 3 after a fresh open", count == 3)
    lib.scanio_close(ctx2)

    # Missing file: should return null and set an error, not crash.
    ctx3 = lib.scanio_open(b"/tmp/libscanio_smoke_test_does_not_exist.csv", None)
    check("scanio_open on a missing file returns null", ctx3 is None or ctx3 == 0)
    err = lib.scanio_last_error()
    check("scanio_last_error is set after a failed open", err is not None)

    # Repeated open/close, the way csvql's Python test guards against
    # allocator faults that only show up once a page boundary is crossed.
    for i in range(200):
        c = lib.scanio_open(tmp.name.encode(), None)
        lib.scanio_close(c)
    total += 1
    passed += 1
    print("PASS  200 consecutive open/close cycles")
finally:
    os.unlink(tmp.name)

print(f"\n{passed}/{total} smoke tests passed")
sys.exit(0 if passed == total else 1)
