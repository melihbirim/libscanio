"""Runs inside the lambda-bench container. Usage:
    python3 run_libscanio.py <csv_path> <where_clause>
Prints `OK rows=N time=Xs peak_rss=YMB` — peak_rss is this PROCESS's
peak RSS (ru_maxrss, KB on Linux), the number that matters for "does
this fit in a Lambda memory tier."
"""
import sys, time, resource

sys.path.insert(0, "/libscanio/python")
import libscanio  # noqa: E402

path, where = sys.argv[1], sys.argv[2]

t0 = time.time()
rows = libscanio.scan_array(path, where=where)
dt = time.time() - t0
peak_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
print(f"OK rows={len(rows)} time={dt:.3f}s peak_rss={peak_mb:.1f}MB")
