# libscanio Python binding

CSV and flat JSON scanning and validation powered by Zig.

```python
import libscanio
ok = libscanio.validate(b"amount\n10\n", {"amount": {"min": 0}})
failures = libscanio.validate(b"amount\n-1\n", {"amount": {"min": 0}}, mode="full")
```

Validation uses a CPython extension that creates rejected Python rows directly.
Fast mode returns a boolean. Full mode returns all failed values and errors.
The previous summary API is `validate_report()`. Other scanning APIs use the
bundled C ABI shared library.

Build from the repository checkout with Zig 0.15.2, CPython 3.10 or newer,
Python development headers and a C compiler:

```sh
python -m pip install ./python
```

For an in-place development build, install setuptools and run
`zig build python-extension`. Both extension and packaged library use
ReleaseFast. Wheels are specific to the Python version and platform.

See the repository README and docs/UPLOAD_VALIDATION.md for details.
