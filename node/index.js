'use strict';

/**
 * libscanio — scan huge CSV files without loading them into memory.
 *
 * N-API binding — compiled directly against Node's own headers, no
 * dynamic FFI layer at all. See src/node_binding.zig's doc comment for
 * the design, and ROADMAP.md's M5b entry for the history.
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
 */

const path = require('path');
const fs = require('fs');

class ScanError extends Error {}

function findAddon() {
  const bundled = path.join(__dirname, 'binaries', `${process.platform}-${process.arch}.node`);
  if (fs.existsSync(bundled)) return require(bundled);

  const dev = path.join(__dirname, '..', 'zig-out', 'lib', 'scanio.node');
  if (fs.existsSync(dev)) return require(dev);

  throw new Error(
    `Could not find scanio.node. Searched:\n  ${bundled}\n  ${dev}\n` +
      'Run `zig build node -Doptimize=ReleaseFast` from the repo root to build it.'
  );
}

let _addon = null;
function addon() {
  if (!_addon) _addon = findAddon();
  return _addon;
}

function call(fn, ...args) {
  try {
    return fn(...args);
  } catch (e) {
    throw new ScanError(e.message);
  }
}

// A row can legitimately carry MORE fields than the header: ragged CSV,
// or a delimiter inside a quoted field (this scanner splits on the
// delimiter and does not treat quotes as grouping — see the README's CSV
// note). Looping to names.length silently DROPPED those values, while
// scanArray() (which returns raw arrays) kept them — the same file gave
// two different answers depending on which function you called. Extra
// fields now get a positional `colN` key, matching the Python client and
// the `scanio` CLI.
function zipRow(names, values) {
  const row = {};
  for (let i = 0; i < values.length; i++) row[i < names.length ? names[i] : `col${i}`] = values[i];
  return row;
}

/** Column names, in header order. Doesn't scan any rows. */
function schema(filePath) {
  return JSON.parse(call(addon().schemaJson, filePath));
}

/** Row count, optionally filtered. With no `where`, never parses a field. */
function count(filePath, where = null) {
  return Number(call(addon().countJson, filePath, where));
}

/**
 * count/sum/min/max/avg over `column`, in one pass. Non-numeric or
 * missing values are skipped, not errors. min/max/avg are null if no
 * numeric value was ever seen (count === 0).
 */
function aggregate(filePath, column, where = null) {
  // `has_values` is a C-ABI detail: C structs have no null, so the ABI
  // reports emptiness in a side flag that the addon faithfully mirrors
  // into its JSON. The addon already nulls min/max/avg when it is false,
  // which leaves the flag redundant — and it was the ONE key making this
  // client's result shape differ from the Python client's for the same
  // file. Dropped here so both expose exactly {count, sum, min, max, avg}.
  const { has_values, ...result } = JSON.parse(call(addon().aggregateJson, filePath, column, where));
  void has_values;
  return result;
}

/**
 * Streaming by default — nothing is materialized until iterated.
 * `columns`: project to these column names, in order. `where`: "col OP
 * val [AND col OP val ...]" or "col IN (a, b, c)". `limit`: stop after
 * this many matching rows.
 */
async function* scan(filePath, options = {}) {
  const { columns, where, limit } = options;
  const columnsJson = columns ? JSON.stringify(columns) : null;
  const { handle, namesJson } = call(addon().openScan, filePath, where ?? null, columnsJson, limit ?? -1);
  const names = JSON.parse(namesJson);
  try {
    let rowJson;
    while ((rowJson = addon().nextRowJson(handle)) !== null) {
      yield zipRow(names, JSON.parse(rowJson));
    }
  } finally {
    addon().closeScan(handle);
  }
}

/**
 * Every matching row back as a real array right now, not streamed —
 * see scan()'s own doc comment for the streaming/bounded-memory
 * tradeoff this does NOT have (materializes the whole result set).
 *
 * Rows are plain arrays of values by default (matching column order),
 * not objects — pass `asObjects: true` for scan()-shaped row objects
 * instead.
 *
 * @returns {Array<Array<string>> | Array<Object>}
 */
function scanArray(filePath, options = {}) {
  const { columns, where, limit, asObjects } = options;
  const columnsJson = columns ? JSON.stringify(columns) : null;
  const { names, rows } = JSON.parse(call(addon().scanArrayJson, filePath, where ?? null, columnsJson, limit ?? -1));
  return asObjects ? rows.map((r) => zipRow(names, r)) : rows;
}

/**
 * Top K rows by `column` (parsed as a number), best-to-worst — one
 * pass, O(N log K), not a full sort. Each returned row is a normal
 * scan()-shaped object plus a `_key` entry with that row's numeric
 * sort value.
 */
function topk(filePath, column, k, where = null, descending = true) {
  const { names, rows, keys } = JSON.parse(call(addon().topkJson, filePath, column, k, where, descending));
  return rows.map((r, i) => ({ ...zipRow(names, r), _key: keys[i] }));
}

/**
 * Every matching row, sorted by `column` (numeric if it parses as one,
 * string compare otherwise). Materializes the whole matching result
 * set before sorting — bounded by the FILTERED row count, not the file
 * size, same tradeoff aggregate()/topk() already accept.
 */
function orderBy(filePath, column, where = null, descending = false) {
  const { names, rows } = JSON.parse(call(addon().orderByJson, filePath, column, where, descending));
  return rows.map((r) => zipRow(names, r));
}

/**
 * A cheap overview for a caller deciding how to query a file it hasn't
 * seen before: column names, total row count, and best-effort
 * aggregates for columns that look numeric.
 *
 * "Looks numeric" is a heuristic: checks whether the first non-empty
 * value in each column (from the first `sampleLimit` rows) parses as a
 * number. Each numeric column costs its own full scan.
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

// Conservative on purpose: unambiguous ISO-ish formats only — no
// MM/DD-vs-DD/MM guessing, no locale-dependent names. A wrong "string"
// classification is a missed nicety; a wrong "datetime" one is
// actively misleading, so this favors false negatives.
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
 * `values`: non-empty sampled strings for one column. Checked
 * most-specific first (boolean, then integer, then float, then
 * datetime) — ALL must match for that classification to apply.
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
 * Column names + an inferred type per column (integer / float /
 * boolean / datetime / string / empty), sampled from the first
 * `sampleSize` rows — bounded cost regardless of file size.
 *
 * A heuristic, not a schema: a column consistent for `sampleSize` rows
 * that changes shape further down won't be caught.
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
