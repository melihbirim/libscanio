import sys, time, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "python"))
import libscanio

path = sys.argv[1]
t0 = time.time()
rows = libscanio.scan_array(path, where="rate_code_id = 6")
dt = time.time() - t0
print(f"rows={len(rows)} time={dt:.4f}s")
