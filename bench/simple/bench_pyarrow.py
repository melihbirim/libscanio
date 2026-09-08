import sys, time
import pyarrow.dataset as ds
import pyarrow.compute as pc

path = sys.argv[1]
fmt = sys.argv[2] if len(sys.argv) > 2 else "csv"
t0 = time.time()
dataset = ds.dataset(path, format="csv" if fmt == "csv" else "json")
n = dataset.to_table(filter=pc.field("category") == "B", columns=["category"]).num_rows
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
