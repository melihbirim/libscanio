import sys, csv, time

path = sys.argv[1]
t0 = time.time()
total = 0
invalid = 0
with open(path, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        total += 1
        bad = False
        try:
            int(row["trip_id"])
        except ValueError:
            bad = True
        try:
            if float(row["fare_amount"]) < 0:
                bad = True
        except ValueError:
            bad = True
        try:
            pc = int(row["passenger_count"])
            if pc < 0 or pc > 9:
                bad = True
        except ValueError:
            bad = True
        try:
            int(row["rate_code_id"])
        except ValueError:
            bad = True
        if bad:
            invalid += 1
dt = time.time() - t0
print(f"rows={total} invalid={invalid} time={dt:.4f}s")
