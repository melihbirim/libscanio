import sys, time
import pyarrow.dataset as ds

path = sys.argv[1]
t0 = time.time()
dataset = ds.dataset(path, format="csv")
n = dataset.count_rows()
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
