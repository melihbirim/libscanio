import sys, time
import pandas as pd

path = sys.argv[1]
fmt = sys.argv[2] if len(sys.argv) > 2 else "csv"
t0 = time.time()
n = 0
if fmt == "csv":
    for chunk in pd.read_csv(path, chunksize=500_000):
        n += (chunk["category"] == "B").sum()
else:
    for chunk in pd.read_json(path, lines=True, chunksize=500_000):
        n += (chunk["category"] == "B").sum()
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
