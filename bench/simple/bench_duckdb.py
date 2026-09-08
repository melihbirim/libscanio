import sys, time
import duckdb

path = sys.argv[1]
fmt = sys.argv[2] if len(sys.argv) > 2 else "csv"
t0 = time.time()
con = duckdb.connect()
if fmt == "csv":
    q = f"SELECT count(*) FROM read_csv_auto('{path}') WHERE category = 'B'"
else:
    q = f"SELECT count(*) FROM read_ndjson_auto('{path}') WHERE category = 'B'"
n = con.execute(q).fetchone()[0]
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
