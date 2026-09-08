import sys, time, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "python"))
import libscanio

path = sys.argv[1]
t0 = time.time()
n = libscanio.count(path, where="category = B")
dt = time.time() - t0
print(f"rows={n} time={dt:.4f}s")
