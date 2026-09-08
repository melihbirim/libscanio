import sys, csv, json, time
path = sys.argv[1]
fmt = sys.argv[2] if len(sys.argv) > 2 else "csv"
t0 = time.time()
n = 0
if fmt == "csv":
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["category"] == "B":
                n += 1
else:
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip() and json.loads(line)["category"] == "B":
                n += 1
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
