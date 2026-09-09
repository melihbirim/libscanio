import sys, time
import polars as pl

path = sys.argv[1]
t0 = time.time()
df = pl.scan_csv(path, infer_schema=False).filter(pl.col("rate_code_id") == "6").collect(engine="streaming")
dt = time.time() - t0
print(f"rows={df.height} time={dt:.4f}s")
