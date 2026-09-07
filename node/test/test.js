'use strict';

// Tests for libscanio's Node binding — the real compiled N-API addon,
// same reasoning as the Python binding's tests: passing Zig tests does
// not prove the built addon works for a real consumer. No test
// framework dependency — plain asserts, same convention as the Python
// binding's test_scan.py.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

process.on('uncaughtException', (e) => {
  console.error('UNCAUGHT EXCEPTION:', e);
  process.exit(1);
});
process.on('unhandledRejection', (e) => {
  console.error('UNHANDLED REJECTION:', e);
  process.exit(1);
});

const libscanio = require('../index');

let passed = 0;
let total = 0;

function check(label, actual, expected) {
  total++;
  try {
    assert.deepStrictEqual(actual, expected);
    console.log(`PASS  ${label}`);
    passed++;
  } catch (e) {
    console.log(`FAIL  ${label}\n    expected: ${JSON.stringify(expected)}\n    actual:   ${JSON.stringify(actual)}`);
  }
}

async function checkRaises(label, fn) {
  total++;
  try {
    await fn();
    console.log(`FAIL  ${label}\n    no exception raised`);
  } catch (e) {
    if (e instanceof libscanio.ScanError) {
      console.log(`PASS  ${label}`);
      passed++;
    } else {
      console.log(`FAIL  ${label}\n    wrong exception: ${e.constructor.name}: ${e.message}`);
    }
  }
}

async function collect(gen) {
  const out = [];
  for await (const row of gen) out.push(row);
  return out;
}

async function main() {
  const P = path.join(os.tmpdir(), `libscanio_test_${process.pid}.csv`);
  fs.writeFileSync(P, 'customer_id,name,revenue\n1,Alice,500\n2,Bob,1500\n3,Carol,2500\n');

  try {
    // The exact target shape from the original ask.
    const rows = await collect(libscanio.scan(P, { columns: ['customer_id', 'revenue'], where: 'revenue > 1000', limit: 100 }));
    check('filtered+projected+limited scan', rows, [
      { customer_id: '2', revenue: '1500' },
      { customer_id: '3', revenue: '2500' },
    ]);

    check('scan with no options returns all columns, all rows', (await collect(libscanio.scan(P))).length, 3);

    const allRows = await collect(libscanio.scan(P));
    check('default row shape includes every column', Object.keys(allRows[0]).sort(), ['customer_id', 'name', 'revenue']);

    check('limit alone', (await collect(libscanio.scan(P, { limit: 1 }))).length, 1);

    check('AND in where', await collect(libscanio.scan(P, { where: 'revenue > 1000 AND name = Bob' })), [
      { customer_id: '2', name: 'Bob', revenue: '1500' },
    ]);

    check(
      'IN in where',
      (await collect(libscanio.scan(P, { where: 'name IN (Alice, Carol)' }))).map((r) => r.customer_id),
      ['1', '3']
    );
    check(
      'IN composes with AND',
      (await collect(libscanio.scan(P, { where: 'name IN (Alice, Carol) AND revenue > 1000' }))).map((r) => r.customer_id),
      ['3']
    );
    check('IN with no matches', await collect(libscanio.scan(P, { where: 'name IN (Zed, Yolanda)' })), []);
    await checkRaises('IN with no values raises', () => collect(libscanio.scan(P, { where: 'name IN ()' })));

    check(
      'scanArray: arrays, filtered+projected',
      libscanio.scanArray(P, { columns: ['customer_id', 'revenue'], where: 'revenue > 1000' }),
      [
        ['2', '1500'],
        ['3', '2500'],
      ]
    );
    check(
      'scanArray: asObjects',
      libscanio.scanArray(P, { columns: ['customer_id', 'revenue'], where: 'revenue > 1000', asObjects: true }),
      [
        { customer_id: '2', revenue: '1500' },
        { customer_id: '3', revenue: '2500' },
      ]
    );
    check('scanArray: no matches returns empty array', libscanio.scanArray(P, { where: 'revenue > 99999' }), []);
    check('scanArray: no filter returns every row', libscanio.scanArray(P).length, 3);

    await checkRaises('unknown column in columns raises', () => collect(libscanio.scan(P, { columns: ['nope'] })));
    await checkRaises('unknown column in where raises', () => collect(libscanio.scan(P, { where: 'nope > 5' })));
    await checkRaises('missing file raises', () => collect(libscanio.scan('/tmp/libscanio_test_does_not_exist.csv')));

    check('schema returns column names in order', libscanio.schema(P), ['customer_id', 'name', 'revenue']);

    check('count with no filter', libscanio.count(P), 3);
    check('count with a filter', libscanio.count(P, 'revenue > 1000'), 2);

    const agg = libscanio.aggregate(P, 'revenue');
    check('aggregate: count', agg.count, 3);
    check('aggregate: sum', agg.sum, 4500);
    check('aggregate: min', agg.min, 500);
    check('aggregate: max', agg.max, 2500);
    check('aggregate: avg', agg.avg, 1500);

    const aggFiltered = libscanio.aggregate(P, 'revenue', 'revenue > 1000');
    check('aggregate composes with where', aggFiltered.count, 2);

    const top2 = libscanio.topk(P, 'revenue', 2);
    check('topk: 2 highest revenue, best first', top2.map((r) => r.customer_id), ['3', '2']);
    check('topk: includes the sort key', top2[0]._key, 2500);
    check('topk: returns every column, not just the sort one', Object.keys(top2[0]).sort(), ['_key', 'customer_id', 'name', 'revenue']);

    const bottom1 = libscanio.topk(P, 'revenue', 1, null, false);
    check('topk: ascending', bottom1[0].customer_id, '1');

    const orderedAsc = libscanio.orderBy(P, 'revenue');
    check('orderBy: ascending, all rows', orderedAsc.map((r) => r.customer_id), ['1', '2', '3']);

    const orderedDesc = libscanio.orderBy(P, 'revenue', null, true);
    check('orderBy: descending', orderedDesc.map((r) => r.customer_id), ['3', '2', '1']);

    const orderedFiltered = libscanio.orderBy(P, 'revenue', 'revenue > 1000', true);
    check('orderBy: composes with where', orderedFiltered.map((r) => r.customer_id), ['3', '2']);

    const orderedEmpty = libscanio.orderBy(P, 'revenue', 'revenue > 99999');
    check('orderBy: empty result set', orderedEmpty, []);

    const desc = await libscanio.describe(P);
    check(
      'describe: basic types',
      Object.fromEntries(desc.map((d) => [d.column, d.type])),
      { customer_id: 'integer', name: 'string', revenue: 'integer' }
    );

    const prof = await libscanio.profile(P);
    check('profile: columns', prof.columns, ['customer_id', 'name', 'revenue']);
    check('profile: rowCount', prof.rowCount, 3);
    check('profile: flags revenue as numeric', 'revenue' in prof.numericColumns, true);
    check('profile: does not flag name as numeric', 'name' in prof.numericColumns, false);
    check('profile: numeric column has real aggregate', prof.numericColumns.revenue.sum, 4500);

    // Regression test mirroring the Python binding's real use-after-free
    // catch: force allocator churn between repeated calls to make sure
    // the WHERE predicate memory genuinely survives the whole scan, not
    // just a lucky first call. Permanent regression guard, same
    // reasoning as the Python side.
    const bigPath = path.join(os.tmpdir(), `libscanio_test_big_${process.pid}.csv`);
    let bigData = 'id,category\n';
    for (let i = 0; i < 500; i++) bigData += `${i},${i % 2 === 0 ? 'even' : 'odd'}\n`;
    fs.writeFileSync(bigPath, bigData);
    try {
      const results = [];
      const gen = libscanio.scan(bigPath, { where: 'category = even' });
      for (let i = 0; i < 300; i++) {
        // eslint-disable-next-line no-unused-vars
        const churn = new Array(500).fill(0).map(() => Buffer.alloc(64));
        const { value, done } = await gen.next();
        if (done) break;
        results.push(value);
      }
      check('scan() survives allocator churn between rows (UAF regression)', results.length, 250);
    } finally {
      fs.unlinkSync(bigPath);
    }

    // 200 consecutive scans — same allocator-fault-only-after-repeated-use
    // reasoning as the Python/C ABI tests.
    for (let i = 0; i < 200; i++) {
      await collect(libscanio.scan(P, { where: `revenue > ${i}` }));
    }
    total++;
    passed++;
    console.log('PASS  200 consecutive scans');
  } finally {
    fs.unlinkSync(P);
  }

  // NDJSON and JSON-array coverage — format inference (.ndjson/.jsonl/
  // .json -> the NDJSON scanner, sniffed from content for .json
  // specifically) happens inside Query.open() itself, with no format
  // option exposed to Node at all — verified end-to-end here, not just
  // assumed from the Zig-level tests. Same fixture shape as the CSV
  // tests above, for direct comparison.
  const ND = path.join(os.tmpdir(), `libscanio_test_${process.pid}.ndjson`);
  fs.writeFileSync(
    ND,
    '{"customer_id":"1","name":"Alice","revenue":"500"}\n' +
      '{"customer_id":"2","name":"Bob","revenue":"1500"}\n' +
      '{"customer_id":"3","name":"Carol","revenue":"2500"}\n'
  );
  const JA = path.join(os.tmpdir(), `libscanio_test_${process.pid}.json`);
  fs.writeFileSync(
    JA,
    '[{"customer_id":"1","name":"Alice","revenue":"500"},' +
      '{"customer_id":"2","name":"Bob","revenue":"1500"},' +
      '{"customer_id":"3","name":"Carol","revenue":"2500"}]'
  );
  try {
    check('ndjson: schema', libscanio.schema(ND), ['customer_id', 'name', 'revenue']);
    check('ndjson: count with no filter', libscanio.count(ND), 3);
    check('ndjson: scan with filter', await collect(libscanio.scan(ND, { where: 'revenue > 1000' })), [
      { customer_id: '2', name: 'Bob', revenue: '1500' },
      { customer_id: '3', name: 'Carol', revenue: '2500' },
    ]);
    check(
      'ndjson: scanArray projected',
      libscanio.scanArray(ND, { columns: ['customer_id', 'revenue'], where: 'revenue > 1000' }),
      [
        ['2', '1500'],
        ['3', '2500'],
      ]
    );
    check('ndjson: aggregate sum', libscanio.aggregate(ND, 'revenue').sum, 4500);

    check('json array: schema', libscanio.schema(JA), ['customer_id', 'name', 'revenue']);
    check('json array: count with no filter', libscanio.count(JA), 3);
    check('json array: scan with filter', await collect(libscanio.scan(JA, { where: 'revenue > 1000' })), [
      { customer_id: '2', name: 'Bob', revenue: '1500' },
      { customer_id: '3', name: 'Carol', revenue: '2500' },
    ]);
    check(
      'json array: scanArray projected',
      libscanio.scanArray(JA, { columns: ['customer_id', 'revenue'], where: 'revenue > 1000' }),
      [
        ['2', '1500'],
        ['3', '2500'],
      ]
    );
    check('json array: aggregate sum', libscanio.aggregate(JA, 'revenue').sum, 4500);
  } finally {
    fs.unlinkSync(ND);
    fs.unlinkSync(JA);
  }

  // describe(): dedicated fixture covering every type category.
  const DESC_P = path.join(os.tmpdir(), `libscanio_test_desc_${process.pid}.csv`);
  fs.writeFileSync(
    DESC_P,
    'id,price,active,created_at,notes\n' +
      '1,19.99,true,2023-05-26T22:00:00Z,\n' +
      '2,29.50,false,2023-06-01T10:15:30Z,\n' +
      '3,9.75,true,2023-07-04T00:00:00Z,\n'
  );
  try {
    const descFull = Object.fromEntries((await libscanio.describe(DESC_P)).map((d) => [d.column, d.type]));
    check('describe: float/boolean/datetime/empty', descFull, {
      id: 'integer',
      price: 'float',
      active: 'boolean',
      created_at: 'datetime',
      notes: 'empty',
    });
  } finally {
    fs.unlinkSync(DESC_P);
  }

  const ALNUM_P = path.join(os.tmpdir(), `libscanio_test_alnum_${process.pid}.csv`);
  fs.writeFileSync(ALNUM_P, 'order_id,amount\nORD001,50\nORD002,1500\n');
  try {
    const descAlnum = Object.fromEntries((await libscanio.describe(ALNUM_P)).map((d) => [d.column, d.type]));
    check('describe: alphanumeric ID column stays string, not integer', descAlnum, { order_id: 'string', amount: 'integer' });
  } finally {
    fs.unlinkSync(ALNUM_P);
  }

  // A row with MORE fields than the header: zipRow() looped to
  // names.length and silently DROPPED the extras, while scanArray()
  // (raw arrays) kept them — the same file answered differently
  // depending on which function you called. A row with FEWER fields
  // than the header crashed the columnar path in Zig, which the Python
  // client surfaced as an IndexError.
  const raggedPath = path.join(os.tmpdir(), `libscanio_ragged_${process.pid}.csv`);
  fs.writeFileSync(raggedPath, 'a,b,c\n1,2,3\n4,5\n6\n7,8,9,EXTRA\n');
  try {
    const ragged = [];
    for await (const r of libscanio.scan(raggedPath)) ragged.push(r);
    check('scan: ragged file yields every row', ragged.length, 4);
    check('scan: a field past the header is kept under a positional key', ragged[3].col3, 'EXTRA');
    check('scan: header columns of that row are still correct',
      [ragged[3].a, ragged[3].b, ragged[3].c], ['7', '8', '9']);
    check('scan: a short row simply omits the missing keys', Object.keys(ragged[2]), ['a']);
    check('scan: normal rows are untouched', ragged[0], { a: '1', b: '2', c: '3' });
    check('scanArray: ragged rows keep their natural width',
      libscanio.scanArray(raggedPath), [['1', '2', '3'], ['4', '5'], ['6'], ['7', '8', '9', 'EXTRA']]);
    check('scanArray(asObjects): agrees with scan()', libscanio.scanArray(raggedPath, { asObjects: true })[3], ragged[3]);
    check('count: unaffected by ragged rows', libscanio.count(raggedPath), 4);
    check('orderBy: ragged file does not throw', libscanio.orderBy(raggedPath, 'a').length, 4);
  } finally {
    fs.unlinkSync(raggedPath);
  }

  // The Python client exposes exactly {count, sum, min, max, avg}; this
  // one used to also leak `has_values`, a C-ABI-only flag (C structs have
  // no null), making the two clients disagree on the shape of the same
  // answer.
  const aggPath = path.join(os.tmpdir(), `libscanio_agg_${process.pid}.csv`);
  fs.writeFileSync(aggPath, 'id,label,amount\n1,alpha,10\n2,beta,20\n');
  try {
    check('aggregate: result shape matches the Python client exactly',
      Object.keys(libscanio.aggregate(aggPath, 'amount')).sort(),
      ['avg', 'count', 'max', 'min', 'sum']);
    const emptyAgg = libscanio.aggregate(aggPath, 'label');
    check('aggregate: a column with no numeric values reports count 0', emptyAgg.count, 0);
    check('aggregate: and nulls min/max/avg rather than reporting zero',
      [emptyAgg.min, emptyAgg.max, emptyAgg.avg], [null, null, null]);
  } finally {
    fs.unlinkSync(aggPath);
  }

  // RFC 4180 quoting, and — just as important — what happens on the one
  // shape the reader cannot represent. Every entry point used to report
  // a mid-scan failure differently: scan() threw a bare Error, and
  // scanArray/topk/orderBy/aggregate swallowed it in the addon and left
  // JavaScript to fail on `JSON.parse('')` with "Unexpected end of JSON
  // input" — an error message that named nothing about the real cause.
  const qPath = path.join(os.tmpdir(), `libscanio_quoted_${process.pid}.csv`);
  fs.writeFileSync(qPath, 'id,"name",city\n1,"Smith, John",London\n2,"He said ""hi""",Paris\n3,he said "hi",Berlin\n');
  try {
    check('quoted CSV: header quoting is stripped', libscanio.schema(qPath), ['id', 'name', 'city']);
    check('quoted CSV: a delimiter inside quotes does not split the field',
      await collect(libscanio.scan(qPath)), [
        { id: '1', name: 'Smith, John', city: 'London' },
        { id: '2', name: 'He said "hi"', city: 'Paris' },
        { id: '3', name: 'he said "hi"', city: 'Berlin' },
      ]);
    check('quoted CSV: scanArray agrees with scan',
      libscanio.scanArray(qPath), [
        ['1', 'Smith, John', 'London'],
        ['2', 'He said "hi"', 'Paris'],
        ['3', 'he said "hi"', 'Berlin'],
      ]);
    check('quoted CSV: a quoted value is filterable by its real content',
      (await collect(libscanio.scan(qPath, { where: 'name = Smith, John' }))).length, 1);
  } finally {
    fs.unlinkSync(qPath);
  }

  // The one shape this reader cannot represent: a record spanning lines.
  const badPath = path.join(os.tmpdir(), `libscanio_badquote_${process.pid}.csv`);
  fs.writeFileSync(badPath, 'a,b\n1,"oops\n');
  try {
    await checkRaises('unterminated quote: scan reports it as a ScanError',
      () => collect(libscanio.scan(badPath)));
    await checkRaises('unterminated quote: scanArray reports it, not a JSON parse error',
      () => libscanio.scanArray(badPath));
    await checkRaises('unterminated quote: aggregate reports it', () => libscanio.aggregate(badPath, 'b'));
    await checkRaises('unterminated quote: topk reports it', () => libscanio.topk(badPath, 'b', 2));
    await checkRaises('unterminated quote: orderBy reports it', () => libscanio.orderBy(badPath, 'b'));
    await checkRaises('unterminated quote: describe reports it', () => libscanio.describe(badPath));
  } finally {
    fs.unlinkSync(badPath);
  }

  // Import validation. The rules live in Zig precisely so this client
  // and the Python one cannot drift apart on them; the differential
  // test checks the two against each other directly.
  const valPath = path.join(os.tmpdir(), `libscanio_validate_${process.pid}.csv`);
  fs.writeFileSync(valPath, 'id,name,amount,status\n1,Alice,100,new\nx,Bob,-5,bogus\n3,,20,paid\n');
  const valSchema = {
    id: { type: 'integer', required: true },
    name: { required: true },
    amount: { type: 'float', min: 0 },
    status: { one_of: ['new', 'paid', 'shipped'] },
  };
  try {
    const r = libscanio.validate(valPath, valSchema);
    check('validate: row totals', [r.rowsTotal, r.rowsValid, r.rowsInvalid], [3, 1, 2]);
    check('validate: ok is false when any row failed', r.ok, false);
    check('validate: every failure is counted', r.errorsTotal, 4);
    check('validate: counts are keyed by rule name', r.counts,
      { bad_type: 1, below_min: 1, not_in_set: 1, missing_required: 1 });
    check('validate: an error names the row, column and offending value', r.errors[0],
      { row: 2, column: 0, column_name: 'id', rule: 'bad_type', value: 'x' });
    check('validate: a clean run reports ok', libscanio.validate(valPath, { name: {} }).ok, true);

    const capped = libscanio.validate(valPath, valSchema, { maxErrors: 2 });
    check('validate: maxErrors caps the stored list', capped.errors.length, 2);
    check('validate: ...but not the totals', capped.errorsTotal, 4);
    check('validate: ...and says so', capped.truncated, true);

    const seen = [];
    for await (const v of libscanio.validateIter(valPath, valSchema)) seen.push(v);
    check('validateIter: yields every row, not just the bad ones', seen.length, 3);
    check('validateIter: rows are numbered from 1, header excluded', seen.map((v) => v.number), [1, 2, 3]);
    check('validateIter: a passing row carries no errors', seen[0].errors, []);
    check('validateIter: a failing row carries the row itself', seen[1].row,
      { id: 'x', name: 'Bob', amount: '-5', status: 'bogus' });
    check('validateIter: ...and every rule it broke',
      seen[1].errors.map((e) => e.rule).sort(), ['bad_type', 'below_min', 'not_in_set']);

    await checkRaises('validate: an unknown column is an error, not an unenforced rule',
      () => libscanio.validate(valPath, { nope: { required: true } }));
    await checkRaises('validate: a misspelled rule name is an error too',
      () => libscanio.validate(valPath, { id: { requred: true } }));
    await checkRaises('validateIter: same, before any row is yielded',
      async () => { for await (const _ of libscanio.validateIter(valPath, { nope: {} })) break; });

    const inferred = await libscanio.inferSchema(valPath);
    check('inferSchema: names every column', Object.keys(inferred).sort(),
      ['amount', 'id', 'name', 'status']);
    check('inferSchema: types what it can, leaves the rest open', inferred.amount, { type: 'integer' });
    check('inferSchema: its own output validates the file it came from',
      libscanio.validate(valPath, inferred).ok, true);
  } finally {
    fs.unlinkSync(valPath);
  }

  // negate: the complement of a WHERE clause. The property that matters
  // is that the two halves PARTITION the file — every row in exactly
  // one, no row in both, none lost.
  const negPath = path.join(os.tmpdir(), `libscanio_negate_${process.pid}.csv`);
  fs.writeFileSync(negPath, 'id,city,amount\n1,London,10\n2,Paris,20\n3,London,30\n4,Berlin,40\n5,Paris,50\n');
  try {
    const kept = libscanio.scanArray(negPath, { where: 'city = London' });
    const dropped = libscanio.scanArray(negPath, { where: 'city = London', negate: true });
    check('negate: scanArray returns the complement', dropped.length, 3);
    check('negate: the two halves partition the file',
      kept.length + dropped.length, libscanio.count(negPath));
    check('negate: no row appears in both halves',
      kept.map((r) => r[0]).filter((id) => dropped.some((d) => d[0] === id)), []);
    check('negate: count agrees with scanArray',
      libscanio.count(negPath, 'city = London', { negate: true }), dropped.length);
    check('negate: scan() streams the same rows scanArray() collects',
      (await collect(libscanio.scan(negPath, { where: 'city = London', negate: true })))
        .map((r) => Object.values(r)),
      dropped);

    // NOT(a AND b) inverts the CONJUNCTION, not each clause.
    check('negate: inverts the whole AND-list, not each clause',
      libscanio.scanArray(negPath, { where: 'city = London AND amount > 20' }).length, 1);
    check('negate: ...so everything else is rejected',
      libscanio.scanArray(negPath, { where: 'city = London AND amount > 20', negate: true }).length, 4);

    check('negate: with no where, nothing matches', libscanio.count(negPath, null, { negate: true }), 0);
    check('negate: ...and scan yields nothing',
      await collect(libscanio.scan(negPath, { negate: true })), []);
    check('negate: composes with columns and limit',
      libscanio.scanArray(negPath, { columns: ['city'], where: 'city = London', limit: 2, negate: true }),
      [['Paris'], ['Berlin']]);
  } finally {
    fs.unlinkSync(negPath);
  }

  const negRagged = path.join(os.tmpdir(), `libscanio_negate_ragged_${process.pid}.csv`);
  fs.writeFileSync(negRagged, 'a,b\n1,10\n2\n3,30\n');
  try {
    check('negate: a truncated row counts as rejected',
      libscanio.count(negRagged, 'b >= 0', { negate: true }), 1);
    check('negate: ...and is not lost from the partition',
      libscanio.count(negRagged, 'b >= 0') + libscanio.count(negRagged, 'b >= 0', { negate: true }),
      libscanio.count(negRagged));
  } finally {
    fs.unlinkSync(negRagged);
  }


  const batchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'scanio-batches-'));
  try {
    for (const format of ['csv', 'ndjson', 'json']) {
      const bp = path.join(batchDir, 'rows.' + format);
      const records = [{a:'1',b:'Zürich'}, {a:'bad',b:'quote"'}, {a:'3',b:'tail'}, {a:'4',b:'last'}];
      fs.writeFileSync(bp, format === 'csv' ? 'a,b\n1,Zürich\nbad,"quote"""\n3,tail\n4,last\n' :
        format === 'json' ? JSON.stringify(records) : records.map(r => JSON.stringify(r)).join('\n'));
      const rules = {a:{type:'integer',min:2}};
      const expected = await collect(libscanio.scan(bp));
      const errors = await collect(libscanio.validateIter(bp, rules));
      for (const batchSize of [1,2,3,8192]) {
        const batches = await collect(libscanio.scanBatches(bp, {batchSize}));
        check(`${format} batches ${batchSize}: order/retention`, batches.flat(), expected);
        check(`${format} batches ${batchSize}: size bound`, batches.every(b => b.length > 0 && b.length <= batchSize), true);
        check(`${format} validation batches ${batchSize}: errors`,
          (await collect(libscanio.validateBatches(bp, rules, {batchSize}))).flat(), errors);
      }
      const opts = {columns:['b'],where:'a = 1',negate:true,limit:2};
      check(`${format} batches: query options`, (await collect(libscanio.scanBatches(bp, opts))).flat(), await collect(libscanio.scan(bp, opts)));
      check(`${format} batches: byte target`, (await collect(libscanio.scanBatches(bp, {targetBytes:1}))).map(b => b.length), [1,1,1,1]);
      check(`${format} batches: arrays`, (await collect(libscanio.scanBatches(bp, {asObjects:false}))).flat(), records.map(r => Object.values(r)));
      for (let i=0;i<10;i++) { for await (const b of libscanio.validateBatches(bp, rules, {batchSize:1})) { break; } }
      for (const options of [{batchSize:0},{batchSize:65537},{batchSize:1.5},{targetBytes:0}]) {
        await assert.rejects(() => collect(libscanio.scanBatches(bp, options)), RangeError);
      }
    }
    const bp = path.join(batchDir, 'ragged.csv');
    fs.writeFileSync(bp, 'a,b\n1,2,extra\n3\n');
    check('batches: ragged rows', (await collect(libscanio.scanBatches(bp))).flat(), await collect(libscanio.scan(bp)));
    check('batches: ragged validation', (await collect(libscanio.validateBatches(bp, {}))).flat(), await collect(libscanio.validateIter(bp, {})));
    fs.writeFileSync(bp, 'a,b\n1,ok\n2,"unterminated\n');
    await checkRaises('batches: malformed row', () => collect(libscanio.scanBatches(bp)));
    await checkRaises('validation batches: malformed row', () => collect(libscanio.validateBatches(bp, {})));
    fs.writeFileSync(bp, 'a,b\n1,nul\x00tail\n');
    check('batches: NUL', (await collect(libscanio.scanBatches(bp)))[0][0].b, 'nul\x00tail');
  } finally { fs.rmSync(batchDir, {recursive:true,force:true}); }

  console.log(`\n${passed}/${total} Node binding tests passed`);
  process.exit(passed === total ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
