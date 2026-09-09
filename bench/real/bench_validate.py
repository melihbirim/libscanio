import sys, time, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "python"))
import libscanio

path = sys.argv[1]
schema = {
    "trip_id": {"type": "integer", "required": True},
    "fare_amount": {"type": "float", "min": 0},
    "passenger_count": {"type": "integer", "min": 0, "max": 9},
    "rate_code_id": {"type": "integer"},
}
t0 = time.time()
report = libscanio.validate_report(path, schema)
dt = time.time() - t0
print(f"rows={report.rows_total} invalid={report.rows_invalid} time={dt:.4f}s")
