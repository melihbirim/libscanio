import sys, time
import duckdb

path = sys.argv[1]
t0 = time.time()
con = duckdb.connect()
rows = con.execute(
    f"SELECT * FROM read_csv_auto('{path}', ALL_VARCHAR=TRUE) WHERE rate_code_id = '6'"
).fetchall()
dt = time.time() - t0
print(f"rows={len(rows)} time={dt:.4f}s")
