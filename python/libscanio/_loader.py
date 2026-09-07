"""
Locates and loads libscanio (.dll on Windows, .dylib on macOS, .so elsewhere).

Search order:
  1. Same directory as this file (installed wheel — lib bundled alongside .py)
  2. zig-out/lib relative to the repo root (development build)
  3. Directories listed in the LIBSCANIO_LIB_PATH environment variable
"""

# os.path, not pathlib: pathlib pulls in urllib.parse and costs ~3.7ms
# of import time, which is a large slice of the total latency of a small
# query (the Zig scan of a 1MB file takes ~2ms).
from __future__ import annotations

import ctypes
import os
import sys

_lib_cache: ctypes.CDLL | None = None


def _lib_name() -> str:
    if sys.platform == "win32":
        return "scanio.dll"
    if sys.platform == "darwin":
        return "libscanio.dylib"
    return "libscanio.so"


def _candidate_dirs() -> list[str]:
    here = os.path.realpath(__file__)
    dirs: list[str] = [os.path.dirname(__file__)]

    parent = os.path.dirname(here)
    while True:
        nxt = os.path.dirname(parent)
        if nxt == parent:
            break
        parent = nxt
        if os.path.exists(os.path.join(parent, "build.zig")):
            # zig-out/lib on POSIX; on Windows the loadable .dll lands in
            # zig-out/bin (zig-out/lib only gets the .lib import stub) —
            # check both rather than special-case by platform, since it's
            # harmless to check a dir that doesn't have the file.
            dirs.append(os.path.join(parent, "zig-out", "lib"))
            dirs.append(os.path.join(parent, "zig-out", "bin"))
            break

    env_path = os.environ.get("LIBSCANIO_LIB_PATH")
    if env_path:
        dirs.append(env_path)

    return dirs


def load() -> ctypes.CDLL:
    global _lib_cache
    if _lib_cache is not None:
        return _lib_cache

    name = _lib_name()
    for d in _candidate_dirs():
        candidate = os.path.join(d, name)
        if os.path.exists(candidate):
            lib = ctypes.CDLL(candidate)
            _setup_signatures(lib)
            _lib_cache = lib
            return lib

    searched = "\n  ".join(os.path.join(d, name) for d in _candidate_dirs())
    raise FileNotFoundError(
        f"Could not find {name}. Searched:\n  {searched}\n"
        "Run `zig build c-lib -Doptimize=ReleaseFast` to build it, "
        "or set LIBSCANIO_LIB_PATH to its directory."
    )


class CPredicate(ctypes.Structure):
    _fields_ = [
        ("column", ctypes.c_size_t),
        ("op", ctypes.c_int),
        ("value", ctypes.c_char_p),
        ("values", ctypes.POINTER(ctypes.c_char_p)),
        ("n_values", ctypes.c_size_t),
    ]


class COptions(ctypes.Structure):
    _fields_ = [
        ("columns", ctypes.POINTER(ctypes.c_size_t)),
        ("n_columns", ctypes.c_size_t),
        ("where", ctypes.POINTER(CPredicate)),
        ("n_where", ctypes.c_size_t),
        ("limit", ctypes.c_int64),
        ("max_column", ctypes.c_int64),
    ]


class CAgg(ctypes.Structure):
    _fields_ = [
        ("count", ctypes.c_uint64),
        ("sum", ctypes.c_double),
        ("min", ctypes.c_double),
        ("max", ctypes.c_double),
        ("avg", ctypes.c_double),
        ("has_values", ctypes.c_int),
    ]


def _setup_signatures(lib: ctypes.CDLL) -> None:
    lib.scanio_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(COptions)]
    lib.scanio_open.restype = ctypes.c_void_p

    lib.scanio_column_index.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.scanio_column_index.restype = ctypes.c_size_t

    lib.scanio_n_columns.argtypes = [ctypes.c_void_p]
    lib.scanio_n_columns.restype = ctypes.c_size_t

    lib.scanio_column_name.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    lib.scanio_column_name.restype = ctypes.c_char_p

    lib.scanio_next.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    lib.scanio_next.restype = ctypes.c_int

    lib.scanio_count.argtypes = [ctypes.c_void_p]
    lib.scanio_count.restype = ctypes.c_int64

    lib.scanio_aggregate.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(CAgg)]
    lib.scanio_aggregate.restype = ctypes.c_int

    lib.scanio_topk.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_int]
    lib.scanio_topk.restype = ctypes.c_void_p

    lib.scanio_topk_next.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)),
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.POINTER(ctypes.c_double),
    ]
    lib.scanio_topk_next.restype = ctypes.c_int

    lib.scanio_topk_close.argtypes = [ctypes.c_void_p]
    lib.scanio_topk_close.restype = None

    lib.scanio_order_by.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    lib.scanio_order_by.restype = ctypes.c_void_p

    lib.scanio_order_by_next.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    lib.scanio_order_by_next.restype = ctypes.c_int

    lib.scanio_order_by_close.argtypes = [ctypes.c_void_p]
    lib.scanio_order_by_close.restype = None

    lib.scanio_collect.argtypes = [ctypes.c_void_p]
    lib.scanio_collect.restype = ctypes.c_void_p

    lib.scanio_collect_data.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
    lib.scanio_collect_data.restype = ctypes.c_void_p  # not c_char_p: length is explicit, data may contain embedded NULs

    lib.scanio_collect_n_rows.argtypes = [ctypes.c_void_p]
    lib.scanio_collect_n_rows.restype = ctypes.c_size_t

    lib.scanio_collect_n_cols.argtypes = [ctypes.c_void_p]
    lib.scanio_collect_n_cols.restype = ctypes.c_size_t

    lib.scanio_collect_close.argtypes = [ctypes.c_void_p]
    lib.scanio_collect_close.restype = None

    lib.scanio_collect_columnar.argtypes = [ctypes.c_void_p]
    lib.scanio_collect_columnar.restype = ctypes.c_void_p

    lib.scanio_parallel_collect_columnar.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char,
        ctypes.POINTER(CPredicate),
        ctypes.c_size_t,
        ctypes.c_size_t,
    ]
    lib.scanio_parallel_collect_columnar.restype = ctypes.c_void_p

    lib.scanio_collect_columnar_n_rows.argtypes = [ctypes.c_void_p]
    lib.scanio_collect_columnar_n_rows.restype = ctypes.c_size_t

    lib.scanio_collect_columnar_n_cols.argtypes = [ctypes.c_void_p]
    lib.scanio_collect_columnar_n_cols.restype = ctypes.c_size_t

    lib.scanio_collect_columnar_data.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    lib.scanio_collect_columnar_data.restype = ctypes.c_void_p  # not c_char_p: no NUL terminator, offsets mark boundaries

    lib.scanio_collect_columnar_offsets.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    lib.scanio_collect_columnar_offsets.restype = ctypes.POINTER(ctypes.c_uint32)

    lib.scanio_collect_columnar_close.argtypes = [ctypes.c_void_p]
    lib.scanio_collect_columnar_close.restype = None

    lib.scanio_validate.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
    lib.scanio_validate.restype = ctypes.c_void_p

    lib.scanio_validate_json.argtypes = [ctypes.c_void_p]
    lib.scanio_validate_json.restype = ctypes.c_char_p

    lib.scanio_validate_free.argtypes = [ctypes.c_void_p]
    lib.scanio_validate_free.restype = None

    lib.scanio_validator_open.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.scanio_validator_open.restype = ctypes.c_void_p

    lib.scanio_validator_next.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.POINTER(ctypes.c_char_p)),
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.POINTER(ctypes.c_char_p),
        ctypes.POINTER(ctypes.c_uint64),
    ]
    lib.scanio_validator_next.restype = ctypes.c_int

    for _fn in ("scanio_validator_rows_total", "scanio_validator_rows_valid", "scanio_validator_rows_invalid"):
        getattr(lib, _fn).argtypes = [ctypes.c_void_p]
        getattr(lib, _fn).restype = ctypes.c_uint64

    lib.scanio_validator_column_name.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    lib.scanio_validator_column_name.restype = ctypes.c_char_p

    lib.scanio_validator_close.argtypes = [ctypes.c_void_p]
    lib.scanio_validator_close.restype = None

    lib.scanio_close.argtypes = [ctypes.c_void_p]
    lib.scanio_close.restype = None

    lib.scanio_last_error.argtypes = []
    lib.scanio_last_error.restype = ctypes.c_char_p
