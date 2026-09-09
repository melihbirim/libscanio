import sys, time
import polars as pl

path = sys.argv[1]
t0 = time.time()
n = pl.scan_csv(path, infer_schema=False).select(pl.len()).collect(engine="streaming").item()
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
