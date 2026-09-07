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

// A row can legitimately carry MORE fields than the header — ragged CSV
// is a real thing and this reader handles it. Looping to names.length
// silently DROPPED those values, while
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
/**
 * Row count. With no `where`, never parses a single field.
 *
 * `negate: true` counts the rows `where` REJECTS instead — the cheapest
 * way to ask "how many rows fail these checks", since no row data
 * crosses back into JavaScript at all. With no `where` it counts
 * nothing, because the negation of "keep everything" is "keep none".
 */
function count(filePath, where = null, options = {}) {
  return Number(call(addon().countJson, filePath, where, options.negate ?? false));
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
 *
 * `negate: true` yields the rows `where` REJECTS instead of the ones it
 * accepts — the complement of the result set. It negates the whole
 * AND-list, not individual clauses; the case it exists for is "give me
 * the rows that failed these checks". With no `where` it yields nothing,
 * since the negation of "keep everything" is "keep none". A row too
 * short to have a predicate's column counts as rejected, so it lands
 * here rather than vanishing from both halves.
 */
async function* scan(filePath, options = {}) {
  const { columns, where, limit, negate = false } = options;
  const columnsJson = columns ? JSON.stringify(columns) : null;
  const { handle, namesJson } = call(addon().openScan, filePath, where ?? null, columnsJson, limit ?? -1, negate);
  const names = JSON.parse(namesJson);
  try {
    let rowJson;
    // Through call(), like every other addon entry point: a mid-scan
    // failure (a malformed row, an unterminated quote) has to surface as
    // a ScanError, not as whatever bare Error the addon threw.
    while ((rowJson = call(addon().nextRowJson, handle)) !== null) {
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
  const { columns, where, limit, asObjects, negate = false } = options;
  const columnsJson = columns ? JSON.stringify(columns) : null;
  const { names, rows } = JSON.parse(
    call(addon().scanArrayJson, filePath, where ?? null, columnsJson, limit ?? -1, negate)
  );
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

/**
 * Check every row against `schema` in one streaming pass, and report
 * what failed.
 *
 * This is the question an import asks, which is the opposite of the one
 * `scan({where})` answers: not "which rows do I want" but "which rows
 * can I not take, and why".
 *
 *     const report = libscanio.validate('orders.csv', {
 *       id:     { type: 'integer', required: true },
 *       amount: { type: 'float', min: 0 },
 *       status: { one_of: ['new', 'paid', 'shipped'] },
 *       email:  { required: true, max_len: 255 },
 *     });
 *     for (const e of report.errors) {
 *       console.log(`row ${e.row}, ${e.column_name}: ${e.rule} (${e.value})`);
 *     }
 *
 * Rule keys: `type` (any/integer/float/boolean/datetime/string),
 * `required`, `min`, `max`, `min_len`, `max_len`, `one_of`. Lengths count
 * characters, not bytes. A blank cell is *absent*, not badly typed — only
 * `required` has anything to say about it.
 *
 * Every schema key must name a real column and every rule name must be
 * spelled correctly; both throw, because a rule that silently does not
 * run is worse than a call that fails.
 *
 * Memory is bounded: rows stream, and only the first `maxErrors` errors
 * are stored (all of them are counted — see `errorsTotal`/`counts`).
 *
 * @returns {{rowsTotal: number, rowsValid: number, rowsInvalid: number,
 *   errorsTotal: number, truncated: boolean, counts: Object,
 *   errors: Array<{row: number, column: number|null, column_name: string,
 *                  rule: string, value: string}>, ok: boolean}}
 */
function validate(filePath, schema, options = {}) {
  const { maxErrors = 100 } = options;
  const raw = JSON.parse(call(addon().validateJson, filePath, JSON.stringify(schema), maxErrors));
  return {
    rowsTotal: raw.rows_total,
    rowsValid: raw.rows_valid,
    rowsInvalid: raw.rows_invalid,
    errorsTotal: raw.errors_total,
    truncated: raw.truncated,
    counts: raw.counts,
    errors: raw.errors,
    ok: raw.rows_invalid === 0,
  };
}

/**
 * Stream every row with its failures attached, as `{row, errors, number}`
 * — `errors` is an empty array for a row that passed.
 *
 * This is the shape an actual import wants, and the reason `validate()`
 * does not return two arrays: the good rows go to the target table and
 * the bad ones to a rejects file in the SAME pass, so neither side is
 * ever materialized and memory stays flat no matter how big the file or
 * how broken it is.
 *
 *     for await (const { row, errors } of libscanio.validateIter(p, schema)) {
 *       if (errors.length) rejects.write(`${row.id},${errors[0].rule}\n`);
 *       else await load(row);
 *     }
 */
async function* validateIter(filePath, schema) {
  const { handle, namesJson } = call(addon().openValidator, filePath, JSON.stringify(schema));
  const names = JSON.parse(namesJson);
  try {
    let json;
    while ((json = call(addon().validatorNextJson, handle)) !== null) {
      const parsed = JSON.parse(json);
      yield {
        number: parsed.number,
        row: zipRow(names, parsed.values),
        // Absent for a clean row, so the common case carries no extra
        // bytes across the boundary.
        errors: parsed.errors ?? [],
      };
    }
  } finally {
    addon().closeValidator(handle);
  }
}

/**
 * Draft a schema from what the file already looks like, using
 * `describe()`'s sampled type inference.
 *
 * A starting point to edit, not a schema to trust: it can only describe
 * the file it read, so a file that is entirely wrong will infer a schema
 * it passes cleanly. Print it, fix it, then pass it to `validate()`.
 *
 * `required: true` marks every column required, which is usually closer
 * to a real import's intent than the default of marking none.
 */
async function inferSchema(filePath, options = {}) {
  const { sampleSize = 1000, required = false } = options;
  const out = {};
  for (const col of await describe(filePath, sampleSize)) {
    const rule = {};
    // "empty" means the sample had no values at all — inferring a type
    // from nothing would be a guess.
    if (col.type !== 'string' && col.type !== 'empty') rule.type = col.type;
    if (required) rule.required = true;
    out[col.column] = rule;
  }
  return out;
}

function checkBatchOptions(batchSize, targetBytes) {
  if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 65536)
    throw new RangeError('batchSize must be an integer in 1..65536');
  if (!Number.isInteger(targetBytes) || targetBytes < 1 || targetBytes > 0x7fffffff)
    throw new RangeError('targetBytes must be an integer in 1..2147483647');
}

/** Yield owned batches; byte target may be exceeded by one complete row.
 * asObjects:false yields arrays. Early break closes the native handle.
 * A malformed row fails its entire batch, with no partial batch yielded.
 */
async function* scanBatches(filePath, options = {}) {
  const { columns, where, limit, negate = false, batchSize = 1024,
    targetBytes = 1048576, asObjects = true } = options;
  checkBatchOptions(batchSize, targetBytes);
  const { handle, namesJson } = call(addon().openScan, filePath, where ?? null,
    columns ? JSON.stringify(columns) : null, limit ?? -1, negate);
  try {
    const names = JSON.parse(namesJson);
    let json;
    while ((json = call(addon().nextBatchJson, handle, batchSize, targetBytes)) !== null) {
      const rows = JSON.parse(json);
      yield asObjects ? rows.map(row => zipRow(names, row)) : rows;
    }
  } finally { addon().closeScan(handle); }
}

/** Yield batches of the same {number,row,errors} items as validateIter().
 * asObjects:false returns array rows. Batch ownership/errors match scanBatches.
 */
async function* validateBatches(filePath, schema, options = {}) {
  const { batchSize = 1024, targetBytes = 1048576, asObjects = true } = options;
  checkBatchOptions(batchSize, targetBytes);
  const { handle, namesJson } = call(addon().openValidator, filePath, JSON.stringify(schema));
  try {
    const names = JSON.parse(namesJson);
    let json;
    while ((json = call(addon().validatorBatchJson, handle, batchSize, targetBytes)) !== null) {
      yield JSON.parse(json).map(item => ({number: item.number,
        row: asObjects ? zipRow(names, item.values) : item.values, errors: item.errors ?? []}));
    }
  } finally { addon().closeValidator(handle); }
}

module.exports = { scanBatches, validateBatches, scan, scanArray, schema, count, aggregate, topk, orderBy, profile, describe, validate, validateIter, inferSchema, ScanError };
