import sys, time
import polars as pl

path = sys.argv[1]
fmt = sys.argv[2] if len(sys.argv) > 2 else "csv"
t0 = time.time()
if fmt == "csv":
    lf = pl.scan_csv(path)
else:
    lf = pl.scan_ndjson(path)
n = lf.filter(pl.col("category") == "B").select(pl.len()).collect(engine="streaming").item()
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
