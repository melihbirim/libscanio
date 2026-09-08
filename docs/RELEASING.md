# Releases

Publishing a stable GitHub release runs `.github/workflows/release.yml`:

1. Check that both package names are `libscanio` and both versions match the
   release tag (`vX.Y.Z`). Prereleases are rejected by this workflow.
2. Build C libraries and call `packages.yml` to build and test Python wheels
   and Node binaries from the release's commit.
3. Attach C libraries, Python wheels, and the npm tarball to the GitHub release.
4. Upload the wheels to PyPI and the npm tarball to npm using trusted publishing.

All builds must pass before registry publishing starts. Publishing jobs live
in `release.yml`, so use that filename for both registries' trusted publishers.
Neither registry requires a token stored in GitHub Secrets.

## One-time registry setup

For PyPI's `libscanio` publisher:

- GitHub owner: `melihbirim`
- Repository: `libscanio`
- Workflow: `release.yml`
- Environment: leave blank (the job does not specify one)

For npm, open the existing `libscanio` package settings and add a GitHub Actions
trusted publisher using the same owner, repository, workflow, and blank
environment. Allow direct `npm publish`. The job uses Node 24 and npm 11,
with provenance enabled. See the [npm instructions](https://docs.npmjs.com/trusted-publishers/)
and [PyPI instructions](https://docs.pypi.org/trusted-publishers/adding-a-publisher/).

## Local release helper

The local, executable `release.sh` is ignored by Git and must never be committed.
After merging this workflow and switching to a clean, up-to-date `main`:

```sh
./release.sh 0.1.1 --dry-run  # preview only
./release.sh 0.1.1            # release an explicit version
./release.sh next             # bump patch: 0.1.0 -> 0.1.1
```

Requires Git, GitHub CLI authenticated with `gh auth login`, and Python 3.11+.
It updates both manifests and the package README install commands, creates a
brief version commit, pushes main, waits for CI, then creates/pushes the tag
and publishes the GitHub release. It waits for the Release workflow to finish.
It stages only the four version-bearing files; `TODO.md` and the helper stay
untracked. It does not change registry credentials or bypass branch protection.
If direct pushes to main are prohibited, use the PR-based steps below instead.

To finish an interrupted release after resolving the cause, use
`./release.sh 0.1.1 --resume`. The current manifest versions must match, and any
existing tag must point at the same commit. For a failed publishing job on an
already-created release, rerun only failed jobs in Actions.

## Publish the next version

1. Update `python/pyproject.toml` and `node/package.json` to the same version.
2. Merge the changes and wait for CI. Keep package README examples current.
3. On GitHub, draft a release with the matching tag, for example `v0.1.1`,
   targeting the reviewed commit on `main`.
4. Publish the GitHub release. Creating or pushing a tag alone does not publish
   packages. Draft releases do not publish packages either.
5. Check the Release workflow and the package pages on PyPI and npm.

npm `0.1.0` was published manually and cannot be overwritten. Use a new version
for the next release. Registry publications are independent, not atomic: if one
fails after the other succeeds, fix its configuration and rerun only failed
jobs. PyPI skips existing files so an interrupted wheel upload can resume.
Never move a published version's tag to different code.

## Build without publishing

Run `Release` manually in Actions to build the same artifacts without uploading
to registries or modifying a GitHub release. `Build packages` also runs on
relevant pull requests and can be run manually; it builds only Python and npm
artifacts and never publishes.

The package matrix produces:

- 25 Python wheels: CPython 3.10–3.14, Linux x64/ARM64 (glibc 2.28+),
  Windows x64, macOS x64/ARM64 (macOS 14+).
- One npm tarball containing addons for all five platforms.
  Alpine/musl and Windows ARM64 are not included.

Python wheels are repaired by cibuildwheel and installed for native API and
Arrow ownership tests. Node binaries run both binding suites on native runners;
the assembled tarball is installed and smoke-tested on Linux. Source distributions
are not published because the Python source package requires the parent Zig
repository to build.
