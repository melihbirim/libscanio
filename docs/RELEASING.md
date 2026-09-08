# Building release packages

`Build packages` (`.github/workflows/packages.yml`) runs on relevant pull
requests, version tags, and manual dispatch. It only builds and tests artifacts;
it does not publish to a registry and needs no PyPI or npm token.

For version 0.1.0 it produces:

- 25 Python wheels: CPython 3.10–3.14, Linux x64/ARM64 (glibc 2.28+),
  Windows x64, macOS x64/ARM64 (macOS 14+).
- One npm tarball containing native addons for those five platforms.
  Linux addons target glibc 2.28; Alpine/musl and Windows ARM64 are not included.

Python wheels are repaired by cibuildwheel and installed for native API and
Arrow buffer ownership tests. Node addons run both binding suites on their
native runners; the assembled tarball is installed and smoke-tested on Linux.
No source distribution is uploaded: the current Python source package needs
the parent Zig repository to build.

After the workflow succeeds, download the `wheels-*` artifacts and the
`npm-package` artifact from its Actions page. Wheel artifact ZIP files must
be extracted before uploading. Keep every platform wheel for the release.

To publish Python from your machine, check the extracted wheels with
`python -m twine check wheelhouse/*.whl`, then upload them with
`python -m twine upload wheelhouse/*.whl`. Twine can prompt for the PyPI token
or retrieve it from the OS keyring. Do not commit credentials.

The existing `Release` workflow publishes C libraries to GitHub Releases.
Registry publishing is separate from both build workflows. Before tagging,
ensure both package manifests and the tag agree on the release version.
