// Validating an import — the "score must be a number over 30" case.
//
// Run:  node examples/validate_import.js

const path = require('path');
const libscanio = require(path.join(__dirname, '..', 'node'));

const FILE = path.join(__dirname, 'scores.csv');

// One rule, two halves: `type` says what shape the cell must be, `min`
// says how big. They are separate on purpose — `min` alone would still
// reject 'abc', but saying `type` makes the intent explicit and gives a
// bad_type error instead of a confusing range one.
//
// 'float' here means "any usable number", integers included. Use
// 'integer' only if a decimal point should itself be an error.
//
// NOTE: `min` is INCLUSIVE. min: 30 means >= 30, so a score of exactly
// 30 passes. For strictly greater than 30 on integer data, use min: 31.
const SCHEMA = { score: { type: 'float', min: 30 } };

(async () => {
  // ── 1. The summary: one pass, bounded memory, no rows returned ──
  const report = libscanio.validate(FILE, SCHEMA);
  console.log(`${report.rowsValid} of ${report.rowsTotal} rows loadable`);
  for (const e of report.errors) {
    console.log(`  row ${e.row}  ${e.column_name}=${JSON.stringify(e.value)}  ${e.rule}`);
  }
  console.log();
  console.log('failures by rule:', report.counts);
  console.log('ok:', report.ok);

  // ── 2. The stream: each row WITH its failures, so both halves of the
  //      import can be written in the same pass ──
  console.log();
  let loaded = 0;
  const rejected = [];
  for await (const { row, errors } of libscanio.validateIter(FILE, SCHEMA)) {
    if (errors.length) rejected.push({ row, errors });
    else loaded++; // ...in real life: insert into the target table
  }
  console.log(`loaded ${loaded}, rejected ${rejected.length}`);
  for (const { row, errors } of rejected) {
    const why = errors.map((e) => `${e.rule}(${JSON.stringify(e.value)})`).join(', ');
    console.log(`  id=${row.id}: ${why}`);
  }

  // ── 3. No schema yet? Draft one from the file and edit it ──
  console.log();
  console.log('inferred draft:', await libscanio.inferSchema(FILE));
  process.exit(report.ok ? 0 : 1);
})();
