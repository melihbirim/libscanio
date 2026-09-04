'use strict';

/**
 * libscanio — scan huge CSV files without loading them into memory.
 *
 *   const libscanio = require('libscanio');
 *
 *   for await (const row of libscanio.scan('10gb.csv', {
 *     columns: ['customer_id', 'revenue'],
 *     where: 'revenue > 1000',
 *     limit: 100,
 *   })) {
 *     console.log(row); // { customer_id: '4821', revenue: '1050' }
 *   }
 *
 * Streaming by default — scan() is an async generator, nothing is
 * materialized until you iterate it. Values are always strings;
 * libscanio has no type inference (same as raw CSV).
 *
 * scanArray() exists for when you actually want every matching row back
 * as a real array right now — see its own doc comment for why that's a
 * different tradeoff, not just a convenience wrapper (mirrors the Python
 * binding's scan_array(), same reasoning).
 */

const koffi = require('koffi');
const { load } = require('./loader');

const OP_MAP = { '>=': 3, '<=': 5, '!=': 1, '=': 0, '>': 2, '<': 4 };
const OP_IN = 6;
const COND_RE = /^(\w+)\s*(>=|<=|!=|>|<|=)\s*(.+)$/;
const IN_RE = /^(\w+)\s+IN\s*\((.*)\)$/;

/**
 * A zero-value COptions struct meaning "no columns, no WHERE, no limit,
 * no bound" — passed instead of JS `null` for scanio_open()'s options
 * parameter. Cleaner and marginally safer than passing null either way,
 * kept for that reason, but NOTE: this was originally written as a fix
 * for a koffi crash on scanio_open() on Windows (traced via CI logging
 * — the call never returned) on the theory that passing null for a
 * typed struct pointer was the problem. It wasn't — the identical crash
 * still happens with this non-null struct in place. Root cause is still
 * unknown; Node binding tests are skipped on Windows in CI until it's
 * actually diagnosed (see ci.yml and ROADMAP.md's M5b entry). Left in
 * place since it's not wrong, just not the fix it was written to be.
 */
const NO_OPTIONS = { columns: null, n_columns: 0, where: null, n_where: 0, limit: -1n, max_column: -1n };

class ScanError extends Error {}

function raiseLastError(fns, fallback) {
  const err = fns.scanio_last_error();
  throw new ScanError(err || fallback);
}

function resolveColumn(fns, ctx, name) {
  const idx = fns.scanio_column_index(ctx, name);
  // size_t(-1) — koffi returns size_t as either number or BigInt
  // depending on magnitude; compare both forms.
  if (idx === -1 || idx === 18446744073709551615n || String(idx) === '18446744073709551615') {
    throw new ScanError(`unknown column: ${JSON.stringify(name)}`);
  }
  return Number(idx);
}

/**
 * Translate a simple "col OP val [AND col OP val ...]" string into typed
 * predicates. Only AND joins clauses — no OR (the C ABI's predicate list
 * is flat-AND-only). "col IN (a, b, c)" is supported as one AND-clause,
 * matching if the field equals any of the listed values.
 */
function parseWhere(fns, ctx, where) {
  const predicates = [];
  for (const rawPart of where.split(' AND ')) {
    const part = rawPart.trim();
    const inMatch = IN_RE.exec(part);
    if (inMatch) {
      const [, col, valsStr] = inMatch;
      const vals = valsStr.split(',').map((v) => v.trim()).filter((v) => v.length > 0);
      if (vals.length === 0) throw new ScanError(`invalid IN condition (no values): "${part}"`);
      predicates.push({
        column: resolveColumn(fns, ctx, col),
        op: OP_IN,
        value: '',
        values: vals,
        n_values: vals.length,
      });
      continue;
    }
    const m = COND_RE.exec(part);
    if (!m) throw new ScanError(`invalid WHERE condition: "${part}"`);
    const [, col, op, val] = m;
    predicates.push({
      column: resolveColumn(fns, ctx, col),
      op: OP_MAP[op],
      value: val.trim(),
      values: null,
      n_values: 0,
    });
  }
  return predicates;
}

/**
 * Shared open logic for scan() and scanArray(): resolve column names +
 * WHERE to indices/predicates via a throwaway probe open, then open for
 * real with the resolved options.
 *
 * `maxColumn`: highest column index anything will ever read from this
 * scan — set whenever it's known (bounds the per-row field split, real
 * measured win, see ROADMAP.md). null/-1 = don't know, splits every
 * field (safe default). Only safe to bound when `columns` is explicitly
 * given for scan()/scanArray() (columns=null means "return everything");
 * always safe for count()/aggregate(), which never return row data.
 */
function openFull(fns, path, { columns, where, limit } = {}) {
  const probe = fns.scanio_open(path, NO_OPTIONS);
  if (!probe) raiseLastError(fns, `failed to open ${JSON.stringify(path)}`);

  let colIndices = null;
  let predicates = [];
  try {
    if (columns) colIndices = columns.map((c) => resolveColumn(fns, probe, c));
    if (where) predicates = parseWhere(fns, probe, where);
  } finally {
    fns.scanio_close(probe);
  }

  let maxColumn = -1n;
  if (colIndices !== null) {
    const needed = colIndices.concat(predicates.map((p) => p.column));
    maxColumn = BigInt(Math.max(...needed));
  }

  const opts = {
    columns: colIndices,
    n_columns: colIndices ? colIndices.length : 0,
    where: predicates.length ? predicates : null,
    n_where: predicates.length,
    limit: limit != null ? BigInt(limit) : -1n,
    max_column: maxColumn,
  };

  const ctx = fns.scanio_open(path, opts);
  if (!ctx) raiseLastError(fns, `failed to open ${JSON.stringify(path)}`);

  const names = columns
    ? columns
    : Array.from({ length: Number(fns.scanio_n_columns(ctx)) }, (_, i) => fns.scanio_column_name(ctx, i));

  return { ctx, names };
}

/**
 * Open with WHERE resolved to predicates — shared setup for count(),
 * aggregate(), and topk(). `extraColumn`: aggregate()/topk() read one
 * column not expressed via WHERE — passing its index lets the bound
 * include it, so the scan is bounded even without a WHERE clause.
 * Always safe to bound here (unlike openFull()) — nothing calling this
 * ever needs "every column" back.
 */
function openFiltered(fns, path, where, extraColumn = null) {
  if (!where && extraColumn === null) {
    const ctx = fns.scanio_open(path, NO_OPTIONS);
    if (!ctx) raiseLastError(fns, `failed to open ${JSON.stringify(path)}`);
    return ctx;
  }

  let predicates = [];
  if (where) {
    const probe = fns.scanio_open(path, NO_OPTIONS);
    if (!probe) raiseLastError(fns, `failed to open ${JSON.stringify(path)}`);
    try {
      predicates = parseWhere(fns, probe, where);
    } finally {
      fns.scanio_close(probe);
    }
  }

  const needed = predicates.map((p) => p.column).concat(extraColumn !== null ? [extraColumn] : []);
  const maxColumn = needed.length ? BigInt(Math.max(...needed)) : -1n;

  const opts = {
    columns: null,
    n_columns: 0,
    where: predicates.length ? predicates : null,
    n_where: predicates.length,
    limit: -1n,
    max_column: maxColumn,
  };

  const ctx = fns.scanio_open(path, opts);
  if (!ctx) raiseLastError(fns, `failed to open ${JSON.stringify(path)}`);
  return ctx;
}

/**
 * Scan a CSV file, yielding one object per matching row.
 *
 * @param {string} filePath
 * @param {{columns?: string[], where?: string, limit?: number}} [options]
 */
async function* scan(filePath, options = {}) {
  const { fns } = load();
  const { ctx, names } = openFull(fns, filePath, options);
  try {
    const fieldsPtr = [null];
    const n = [0];
    while (true) {
      const rc = fns.scanio_next(ctx, fieldsPtr, n);
      if (rc === 0) return;
      if (rc < 0) raiseLastError(fns, 'scan failed');
      const nFields = Number(n[0]);
      const values = koffi.decode(fieldsPtr[0], 'str', nFields);
      const row = {};
      for (let i = 0; i < nFields; i++) row[names[i]] = values[i];
      yield row;
    }
  } finally {
    fns.scanio_close(ctx);
  }
}

/**
 * Like scan(), but for when you actually want every matching row back as
 * a real array right now, not streamed. Collects the whole result in Zig
 * first and hands it to JS as one bulk buffer decode, instead of one
 * small FFI call per field per row — real, measured win once you were
 * going to materialize the result anyway (see docs/BENCHMARKS.md and
 * ROADMAP.md's scan_array()/stop_after_column entries — same fix, this
 * is its Node counterpart).
 *
 * Not memory-bounded the way scan() is — this materializes every
 * matching row in both Zig and JS at once. Use scan() and don't collect
 * an array if the actual goal is staying within bounded memory on a huge
 * file.
 *
 * @returns {Array<Array<string>> | Array<Object>}
 */
function scanArray(filePath, options = {}) {
  const { fns } = load();
  // Multi-threaded by default (parallelScan, the same engine
  // count()/aggregate()-style parallel entry points already use)
  // whenever there's no projection/limit — the common case, and the
  // one this binding did NOT use until an N-way concurrency experiment
  // showed the old single-threaded scanio_collect() path here was real
  // and measured: 1.3GB/6.2s for 1.24M matching rows on a real 10-
  // column fixture with the old path; 15-895MB/0.05-0.47s across N=1-32
  // CONCURRENT processes with this one, on the same real data — genuinely
  // faster and leaner than duckdb on the identical task. `columns`/
  // `limit` fall back to the single-threaded path below (parallelScan
  // doesn't support projection or a row limit yet — real, current scope
  // gap, not silently wrong). See ROADMAP.md.
  if (!options.columns && options.limit == null) {
    return scanArrayParallel(fns, filePath, options);
  }
  return scanArraySingleThreaded(fns, filePath, options);
}

function scanArraySingleThreaded(fns, filePath, options) {
  const { ctx, names } = openFull(fns, filePath, options);
  try {
    const cc = fns.scanio_collect(ctx);
    if (!cc) raiseLastError(fns, 'collect failed');
    try {
      const nRows = Number(fns.scanio_collect_n_rows(cc));
      const nCols = Number(fns.scanio_collect_n_cols(cc));
      if (nRows === 0) return [];

      const len = [0];
      const dataPtr = fns.scanio_collect_data(cc, len);
      const bytes = koffi.decode(dataPtr, koffi.array('uint8_t', Number(len[0])));
      const text = Buffer.from(bytes).toString('utf8');
      const parts = text.split('\0');
      parts.pop(); // trailing empty string from the last NUL

      const rows = new Array(nRows);
      if (options.asObjects) {
        for (let i = 0; i < nRows; i++) {
          const row = {};
          for (let j = 0; j < nCols; j++) row[names[j]] = parts[i * nCols + j];
          rows[i] = row;
        }
      } else {
        for (let i = 0; i < nRows; i++) rows[i] = parts.slice(i * nCols, (i + 1) * nCols);
      }
      return rows;
    } finally {
      fns.scanio_collect_close(cc);
    }
  } finally {
    fns.scanio_close(ctx);
  }
}

function scanArrayParallel(fns, filePath, options) {
  const names = schema(filePath);

  const probe = fns.scanio_open(filePath, NO_OPTIONS);
  if (!probe) raiseLastError(fns, `failed to open ${JSON.stringify(filePath)}`);
  let predicates = [];
  try {
    if (options.where) predicates = parseWhere(fns, probe, options.where);
  } finally {
    fns.scanio_close(probe);
  }

  const cc = fns.scanio_parallel_collect_columnar(
    filePath,
    ','.charCodeAt(0),
    predicates.length ? predicates : null,
    predicates.length,
    0
  );
  if (!cc) raiseLastError(fns, 'parallel scan failed');
  try {
    const nRows = Number(fns.scanio_collect_columnar_n_rows(cc));
    const nCols = Number(fns.scanio_collect_columnar_n_cols(cc));
    if (nRows === 0) return [];

    const columnsData = [];
    for (let col = 0; col < nCols; col++) {
      const dataLen = [0];
      const dataPtr = fns.scanio_collect_columnar_data(cc, col, dataLen);
      const bytes = dataPtr ? koffi.decode(dataPtr, koffi.array('uint8_t', Number(dataLen[0]))) : new Uint8Array(0);
      const buf = Buffer.from(bytes);

      const offLen = [0];
      const offPtr = fns.scanio_collect_columnar_offsets(cc, col, offLen);
      const offsets = koffi.decode(offPtr, koffi.array('uint32_t', Number(offLen[0])));

      const values = new Array(nRows);
      for (let i = 0; i < nRows; i++) values[i] = buf.toString('utf8', offsets[i], offsets[i + 1]);
      columnsData.push(values);
    }

    const rows = new Array(nRows);
    if (options.asObjects) {
      for (let i = 0; i < nRows; i++) {
        const row = {};
        for (let j = 0; j < nCols; j++) row[names[j]] = columnsData[j][i];
        rows[i] = row;
      }
    } else {
      for (let i = 0; i < nRows; i++) rows[i] = columnsData.map((col) => col[i]);
    }
    return rows;
  } finally {
    fns.scanio_collect_columnar_close(cc);
  }
}

/** Column names, in header order. Doesn't scan any rows. */
function schema(filePath) {
  const { fns } = load();
  const ctx = fns.scanio_open(filePath, NO_OPTIONS);
  if (!ctx) raiseLastError(fns, `failed to open ${JSON.stringify(filePath)}`);
  try {
    const n = Number(fns.scanio_n_columns(ctx));
    return Array.from({ length: n }, (_, i) => fns.scanio_column_name(ctx, i));
  } finally {
    fns.scanio_close(ctx);
  }
}

/** Row count. With no `where`, never parses a single field. */
function count(filePath, where = null) {
  const { fns } = load();
  const ctx = openFiltered(fns, filePath, where);
  try {
    const n = fns.scanio_count(ctx);
    if (n < 0) raiseLastError(fns, 'count failed');
    return Number(n);
  } finally {
    fns.scanio_close(ctx);
  }
}

/**
 * count/sum/min/max/avg over `column`, in one pass. Non-numeric or
 * missing values are skipped, not errors. min/max/avg are null if no
 * numeric value was ever seen (count === 0).
 */
function aggregate(filePath, column, where = null) {
  const { fns } = load();
  const probe = fns.scanio_open(filePath, NO_OPTIONS);
  if (!probe) raiseLastError(fns, `failed to open ${JSON.stringify(filePath)}`);
  let colIdx;
  try {
    colIdx = resolveColumn(fns, probe, column);
  } finally {
    fns.scanio_close(probe);
  }

  const ctx = openFiltered(fns, filePath, where, colIdx);
  try {
    const buf = [{}];
    const rc = fns.scanio_aggregate(ctx, colIdx, buf);
    if (rc !== 0) raiseLastError(fns, 'aggregate failed');
    const res = buf[0];
    const hasValues = !!res.has_values;
    return {
      count: Number(res.count),
      sum: res.sum,
      min: hasValues ? res.min : null,
      max: hasValues ? res.max : null,
      avg: hasValues ? res.avg : null,
    };
  } finally {
    fns.scanio_close(ctx);
  }
}

/**
 * Top K rows by `column` (parsed as a number), best-to-worst — one pass,
 * O(N log K), not a full sort. Each returned row is a normal scan()-shaped
 * object plus a `_key` entry with that row's numeric value for the sorted
 * column.
 */
function topk(filePath, column, k, where = null, descending = true) {
  const { fns } = load();
  const probe = fns.scanio_open(filePath, NO_OPTIONS);
  if (!probe) raiseLastError(fns, `failed to open ${JSON.stringify(filePath)}`);
  let colIdx;
  try {
    colIdx = resolveColumn(fns, probe, column);
  } finally {
    fns.scanio_close(probe);
  }

  // topk() deliberately does NOT bound the scan to colIdx — it returns
  // full rows (every column), same as the Python binding; bounding here
  // would silently truncate the returned rows. See ROADMAP.md.
  const ctx = openFiltered(fns, filePath, where);
  try {
    const n = Number(fns.scanio_n_columns(ctx));
    const names = Array.from({ length: n }, (_, i) => fns.scanio_column_name(ctx, i));

    const tctx = fns.scanio_topk(ctx, colIdx, k, descending ? 1 : 0);
    if (!tctx) raiseLastError(fns, 'topk failed');
    try {
      const results = [];
      const fieldsPtr = [null];
      const nOut = [0];
      const keyOut = [0];
      while (true) {
        const rc = fns.scanio_topk_next(tctx, fieldsPtr, nOut, keyOut);
        if (rc === 0) break;
        if (rc < 0) raiseLastError(fns, 'topk failed');
        const nFields = Number(nOut[0]);
        const values = koffi.decode(fieldsPtr[0], 'str', nFields);
        const row = {};
        for (let i = 0; i < nFields; i++) row[names[i]] = values[i];
        row._key = keyOut[0];
        results.push(row);
      }
      return results;
    } finally {
      fns.scanio_topk_close(tctx);
    }
  } finally {
    fns.scanio_close(ctx);
  }
}

/**
 * Every matching row, sorted by `column` (numeric if the column parses as
 * one, string compare otherwise — same rule `where`'s predicates already
 * use). Materializes the whole matching result set before sorting, same
 * memory tradeoff aggregate()/topk() already accept: bounded by the
 * FILTERED row count, not the file size. See ROADMAP.md's M10 entry.
 */
function orderBy(filePath, column, where = null, descending = false) {
  const { fns } = load();
  const probe = fns.scanio_open(filePath, NO_OPTIONS);
  if (!probe) raiseLastError(fns, `failed to open ${JSON.stringify(filePath)}`);
  let colIdx;
  try {
    colIdx = resolveColumn(fns, probe, column);
  } finally {
    fns.scanio_close(probe);
  }

  const ctx = openFiltered(fns, filePath, where);
  try {
    const n = Number(fns.scanio_n_columns(ctx));
    const names = Array.from({ length: n }, (_, i) => fns.scanio_column_name(ctx, i));

    const octx = fns.scanio_order_by(ctx, colIdx, descending ? 1 : 0);
    if (!octx) raiseLastError(fns, 'order_by failed');
    try {
      const results = [];
      const fieldsPtr = [null];
      const nOut = [0];
      while (true) {
        const rc = fns.scanio_order_by_next(octx, fieldsPtr, nOut);
        if (rc === 0) break;
        if (rc < 0) raiseLastError(fns, 'order_by failed');
        const nFields = Number(nOut[0]);
        const values = koffi.decode(fieldsPtr[0], 'str', nFields);
        const row = {};
        for (let i = 0; i < nFields; i++) row[names[i]] = values[i];
        results.push(row);
      }
      return results;
    } finally {
      fns.scanio_order_by_close(octx);
    }
  } finally {
    fns.scanio_close(ctx);
  }
}

/**
 * A cheap overview for a caller deciding how to query a file it hasn't
 * seen before: column names, total row count, and best-effort aggregates
 * for columns that look numeric.
 *
 * "Looks numeric" is a heuristic, not a schema: it checks whether the
 * first non-empty value in each column (from the first `sampleLimit`
 * rows) parses as a number. Each numeric column costs its own full scan
 * (aggregate() is one pass per column, not one pass total) — fine for an
 * occasional profile() call, not something to run in a hot loop.
 */
async function profile(filePath, sampleLimit = 1) {
  const cols = schema(filePath);
  const totalRows = count(filePath);

  const sampleRows = [];
  for await (const row of scan(filePath, { limit: sampleLimit })) sampleRows.push(row);

  const numericCols = [];
  for (const col of cols) {
    for (const row of sampleRows) {
      const val = row[col] ?? '';
      if (val === '') continue;
      if (!Number.isNaN(Number(val))) numericCols.push(col);
      break;
    }
  }

  const numericColumns = {};
  for (const col of numericCols) numericColumns[col] = aggregate(filePath, col);

  return { columns: cols, rowCount: totalRows, numericColumns };
}

// Conservative on purpose: unambiguous ISO-ish formats only, checked with
// a fixed regex per format rather than a general date parser (JS's Date
// constructor accepts far more than real ISO 8601 and silently reinterprets
// ambiguous strings) — no MM/DD-vs-DD/MM guessing, no locale-dependent
// names. A wrong "string" classification is a missed nicety; a wrong
// "datetime" one is actively misleading, so this favors false negatives.
const DATETIME_PATTERNS = [
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/,
  /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/,
  /^\d{4}-\d{2}-\d{2}$/,
];

function isDatetime(v) {
  return DATETIME_PATTERNS.some((re) => re.test(v)) && !Number.isNaN(Date.parse(v));
}

/**
 * `values`: non-empty sampled strings for one column. Checked most-specific
 * first (boolean, then integer, then float, then datetime) — ALL must
 * match for that classification to apply, same reasoning as the Python
 * binding's _infer_column_type(): a bounded sample is already forgiving of
 * rare exceptions further down the file, so requiring every SAMPLED value
 * to agree keeps false positives low.
 */
function inferColumnType(values) {
  if (values.length === 0) return 'empty';
  if (values.every((v) => v.toLowerCase() === 'true' || v.toLowerCase() === 'false')) return 'boolean';
  if (values.every((v) => /^-?\d+$/.test(v))) return 'integer';
  if (values.every((v) => v !== '' && !Number.isNaN(Number(v)))) return 'float';
  if (values.every(isDatetime)) return 'datetime';
  return 'string';
}

/**
 * Column names + an inferred type per column (integer / float / boolean /
 * datetime / string / empty), sampled from the first `sampleSize` rows —
 * bounded cost regardless of file size, same tradeoff profile()'s own
 * numeric-column detection accepts.
 *
 * A heuristic, not a schema: a column consistent for `sampleSize` rows
 * that changes shape further down won't be caught. Datetime detection is
 * deliberately conservative — see DATETIME_PATTERNS above.
 */
async function describe(filePath, sampleSize = 1000) {
  const cols = schema(filePath);
  const sampleRows = [];
  for await (const row of scan(filePath, { limit: sampleSize })) sampleRows.push(row);

  return cols.map((col) => {
    const nonEmpty = sampleRows.map((r) => r[col] ?? '').filter((v) => v !== '');
    return { column: col, type: inferColumnType(nonEmpty) };
  });
}

module.exports = { scan, scanArray, schema, count, aggregate, topk, orderBy, profile, describe, ScanError };
