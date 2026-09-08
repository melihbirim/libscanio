# libscanio Python binding

CSV and flat JSON scanning and validation powered by Zig.

```python
import libscanio
ok = libscanio.validate(b"amount\n10\n", {"amount": {"min": 0}})
failures = libscanio.validate(b"amount\n-1\n", {"amount": {"min": 0}}, mode="full")
```

All public APIs use a CPython extension with the Zig core statically linked.
Rows and validation errors are constructed directly through the Python C API.
Fast mode returns a boolean. Full mode returns all failed values and errors.
The previous summary API is `validate_report()`. Arrow uses native buffer
ownership. The bundled C ABI library is retained for private diagnostics; public
APIs do not require it.

Build from the repository checkout with Zig 0.15.2, CPython 3.10 or newer,
Python development headers and a C compiler:

```sh
python -m pip install ./python
```

For an in-place development build, install setuptools and run
`zig build python-extension`. Both extension and packaged library use
ReleaseFast. Wheels are specific to the Python version and platform.

See the repository README and docs/UPLOAD_VALIDATION.md for details.
