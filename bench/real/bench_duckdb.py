import sys, time
import duckdb

path = sys.argv[1]
t0 = time.time()
con = duckdb.connect()
n = con.execute(
    f"SELECT count(*) FROM read_csv_auto('{path}', ALL_VARCHAR=TRUE) WHERE rate_code_id = '6'"
).fetchone()[0]
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
