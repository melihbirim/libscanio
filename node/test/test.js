'use strict';

// Tests for libscanio's Node binding — the actual dlopen() path via
// koffi, same reasoning as the Python binding's tests: passing Zig
// tests does not prove the built shared library works for a real
// consumer. No test framework dependency — plain asserts, same
// convention as the Python binding's test_scan.py.

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

const libscanio = require('../lib/index');

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

    const prof = await libscanio.profile(P);
    check('profile: columns', prof.columns, ['customer_id', 'name', 'revenue']);
    check('profile: rowCount', prof.rowCount, 3);
    check('profile: flags revenue as numeric', 'revenue' in prof.numericColumns, true);
    check('profile: does not flag name as numeric', 'name' in prof.numericColumns, false);
    check('profile: numeric column has real aggregate', prof.numericColumns.revenue.sum, 4500);

    // Regression test mirroring the Python binding's real use-after-free
    // catch: force allocator churn between repeated FFI calls to make
    // sure the WHERE predicate memory genuinely survives the whole scan,
    // not just a lucky first call. Verified koffi handles this safely
    // (see the session's koffi_test4.js investigation) but keep this as
    // a permanent regression guard, same reasoning as the Python side.
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

  // NDJSON and JSON-array coverage — real gap until now: format
  // inference (.ndjson/.jsonl/.json -> the NDJSON scanner, sniffed from
  // content for .json specifically) happens at the C ABI level with no
  // format option exposed to Node at all, so this was "should work, per
  // the Zig-level tests" rather than actually verified through koffi.
  // Same fixture shape as the CSV tests above, for direct comparison.
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

  console.log(`\n${passed}/${total} Node binding tests passed`);
  process.exit(passed === total ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
