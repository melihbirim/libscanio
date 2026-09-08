# CPython validation extension

`validate()` calls a CPython extension, with the Zig validator statically linked
behind a small C shim. Fast mode returns a Python boolean. Full mode constructs
only failed rows and errors with the Python C API; no row JSON is serialized or
parsed. The schema is still encoded as JSON once per call.

The existing API is unchanged:

```python
import libscanio
ok = libscanio.validate(uploaded_bytes, schema)
failures = libscanio.validate(uploaded_bytes, schema, mode="full")
```

Field strings are reused in corresponding errors. Dictionary keys, column names
and rule names are shared within each result. Private acyclic result containers
are kept out of GC tracking during construction, then tracked before returning
them to mutable Python callers. This avoids repeated GC traversal of a growing
result without changing the application's global GC settings. Tests exercise
mutation, caller-created cycles, partial-result cleanup and retained strings.

The extension holds the GIL during validation and checks Python signals every
1,024 records. This version does not provide concurrent Python-thread execution
while scanning. Bytes and file paths are supported; incremental upload streams
are not. Full mode still uses memory proportional to all failures.

## Build and packaging

From a checkout, with Zig 0.15.2, CPython development headers and a C compiler:

```sh
python -m pip install setuptools wheel
zig build python-extension
zig build python-test -Doptimize=ReleaseFast
python -m pip install ./python
```

Both the extension and packaged shared library use ReleaseFast. All public Python
APIs now use the extension; see [API migration](CPYTHON_API_MIGRATION.md). The extension has no runtime
dependency on that shared library. Wheels are specific to CPython version,
platform and architecture. Installed-wheel tests run outside the checkout.
macOS archive members are repacked for Apple's alignment requirements; Windows
builds target the MSVC ABI. Linux/Windows validation is configured in CI and has
not been run locally for this change.

## Speed and memory

200,000 uploaded CSV records, five fresh processes per case/mode/engine,
ReleaseFast, macOS arm64, Python 3.14.4. Each child loads its module and input
bytes before timing; there is no query warmup. Time includes validation and
Python result construction, excludes imports and upload/download. Peak RSS
includes interpreter and input and is sampled before result hashing. Baseline
Python uses csv.reader plus a handwritten float/minimum check, specialized to
these fixtures. Outputs are checked for exact equality across all three engines.
No compilation or other benchmark runs overlap the recorded measurements.

| Input | Mode | CPython extension | JSON bridge | Handwritten Python |
|---|---|---:|---:|---:|
| valid | fast | 7.063 ms / 20.0 MiB | 7.526 ms / 20.1 MiB | 40.319 ms / 18.4 MiB |
| valid | full | 6.872 ms / 20.0 MiB | 7.464 ms / 20.2 MiB | 40.476 ms / 18.2 MiB |
| first invalid | fast | 0.070 ms / 20.0 MiB | 0.065 ms / 20.0 MiB | 0.025 ms / 18.3 MiB |
| one percent invalid | full | 7.850 ms / 21.3 MiB | 10.041 ms / 22.4 MiB | 43.819 ms / 19.6 MiB |
| all invalid | full | 92.468 ms / 144.3 MiB | 234.486 ms / 281.8 MiB | 124.728 ms / 145.8 MiB |

Full mode with every row invalid improves from approximately 234 ms / 282 MiB
through JSON to 92 ms / 144 MiB. Handwritten Python measures 125 ms / 146 MiB.
This is about 2.5x faster than the JSON bridge and 1.35x faster than Python in
this fixture. Immediate failure remains dominated by call/setup overhead and
is faster in handwritten Python. These are local measurements, not Lambda
latency guarantees or evidence for every schema and file shape.

Reproduce with `python3 bench/upload_validation_memory.py` on macOS/Linux.
The script writes [raw samples](CPYTHON_VALIDATION_BENCHMARKS.json).
