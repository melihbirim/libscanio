'use strict';

/**
 * Locates and loads libscanio (.dylib on macOS, .so elsewhere, .dll on
 * Windows) via koffi (dynamic FFI, no native compilation step — same
 * "works immediately after npm install" property the Python binding has
 * via ctypes).
 *
 * Search order matches the Python binding's _loader.py:
 *   1. Same directory as this file (installed package — lib bundled alongside)
 *   2. zig-out/lib relative to the repo root (development build)
 *   3. Directories listed in the LIBSCANIO_LIB_PATH environment variable
 */

const koffi = require('koffi');
const fs = require('fs');
const path = require('path');
const os = require('os');

let cached = null;

function libName() {
  if (process.platform === 'win32') return 'scanio.dll';
  if (process.platform === 'darwin') return 'libscanio.dylib';
  return 'libscanio.so';
}

function candidateDirs() {
  const dirs = [__dirname];

  let dir = __dirname;
  for (let i = 0; i < 10; i++) {
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
    if (fs.existsSync(path.join(dir, 'build.zig'))) {
      // zig-out/lib on POSIX; on Windows the loadable .dll lands in
      // zig-out/bin (zig-out/lib only gets the .lib import stub) — check
      // both rather than special-case by platform.
      dirs.push(path.join(dir, 'zig-out', 'lib'));
      dirs.push(path.join(dir, 'zig-out', 'bin'));
      break;
    }
  }

  if (process.env.LIBSCANIO_LIB_PATH) dirs.push(process.env.LIBSCANIO_LIB_PATH);

  return dirs;
}

function load() {
  if (cached) return cached;

  const name = libName();
  for (const dir of candidateDirs()) {
    const candidate = path.join(dir, name);
    if (fs.existsSync(candidate)) {
      cached = build(candidate);
      return cached;
    }
  }

  const searched = candidateDirs().map((d) => path.join(d, name)).join(os.EOL + '  ');
  throw new Error(
    `Could not find ${name}. Searched:${os.EOL}  ${searched}${os.EOL}` +
      'Run `zig build c-lib -Doptimize=ReleaseFast` to build it, ' +
      'or set LIBSCANIO_LIB_PATH to its directory.'
  );
}

function build(libPath) {
  const lib = koffi.load(libPath);

  const CPredicate = koffi.struct('CPredicate', {
    column: 'size_t',
    op: 'int',
    value: 'str',
    values: koffi.pointer('str'),
    n_values: 'size_t',
  });

  const COptions = koffi.struct('COptions', {
    columns: koffi.pointer('size_t'),
    n_columns: 'size_t',
    where: koffi.pointer(CPredicate),
    n_where: 'size_t',
    limit: 'int64_t',
    max_column: 'int64_t',
  });

  const CAgg = koffi.struct('CAgg', {
    count: 'uint64_t',
    sum: 'double',
    min: 'double',
    max: 'double',
    avg: 'double',
    has_values: 'int',
  });

  return {
    types: { CPredicate, COptions, CAgg },
    fns: {
      scanio_open: lib.func('void *scanio_open(str, COptions *)'),
      scanio_column_index: lib.func('size_t scanio_column_index(void *, str)'),
      scanio_n_columns: lib.func('size_t scanio_n_columns(void *)'),
      scanio_column_name: lib.func('str scanio_column_name(void *, size_t)'),
      scanio_next: lib.func('int scanio_next(void *, _Out_ void **, _Out_ size_t *)'),
      scanio_count: lib.func('int64_t scanio_count(void *)'),
      scanio_aggregate: lib.func('int scanio_aggregate(void *, size_t, _Out_ CAgg *)'),
      scanio_topk: lib.func('void *scanio_topk(void *, size_t, size_t, int)'),
      scanio_topk_next: lib.func('int scanio_topk_next(void *, _Out_ void **, _Out_ size_t *, _Out_ double *)'),
      scanio_topk_close: lib.func('void scanio_topk_close(void *)'),
      scanio_collect: lib.func('void *scanio_collect(void *)'),
      scanio_collect_data: lib.func('void *scanio_collect_data(void *, _Out_ size_t *)'),
      scanio_collect_n_rows: lib.func('size_t scanio_collect_n_rows(void *)'),
      scanio_collect_n_cols: lib.func('size_t scanio_collect_n_cols(void *)'),
      scanio_collect_close: lib.func('void scanio_collect_close(void *)'),
      scanio_close: lib.func('void scanio_close(void *)'),
      scanio_last_error: lib.func('str scanio_last_error()'),
    },
  };
}

module.exports = { load };
