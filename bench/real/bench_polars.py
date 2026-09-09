import sys, time
import polars as pl

path = sys.argv[1]
t0 = time.time()
lf = pl.scan_csv(path, infer_schema=False)
n = lf.filter(pl.col("rate_code_id") == "6").select(pl.len()).collect(engine="streaming").item()
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
