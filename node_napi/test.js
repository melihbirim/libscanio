// Real, comprehensive test for the N-API addon — no mocks, exercises
// every exported function directly against the compiled zig-out
// binary. This is the replacement path for the koffi-based node/
// package (see src/node_binding.zig's doc comment for why) — same
// fixture shape as node/test/test.js so results are directly
// comparable to the koffi binding's own known-correct output.
const path = require('path');
const os = require('os');
const fs = require('fs');

const addonPath = path.join(__dirname, '..', 'zig-out', 'lib', 'scanio.node');
const addon = require(addonPath);

let passed = 0;
let total = 0;

function check(label, actual, expected) {
  total++;
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    console.log(`PASS  ${label}`);
    passed++;
  } else {
    console.log(`FAIL  ${label}\n    expected: ${e}\n    actual:   ${a}`);
  }
}

function checkThrows(label, fn) {
  total++;
  try {
    fn();
    console.log(`FAIL  ${label}\n    no exception raised`);
  } catch (e) {
    console.log(`PASS  ${label}`);
    passed++;
  }
}

const P = path.join(os.tmpdir(), `libscanio_napi_test_${process.pid}.csv`);
fs.writeFileSync(P, 'customer_id,name,revenue\n1,Alice,500\n2,Bob,1500\n3,Carol,2500\n');

try {
  // schema
  check('schemaJson', JSON.parse(addon.schemaJson(P)), ['customer_id', 'name', 'revenue']);
  checkThrows('schemaJson on missing file throws', () => addon.schemaJson('/does/not/exist_12345.csv'));

  // count
  check('countJson: no filter', addon.countJson(P), 3);
  check('countJson: with WHERE', addon.countJson(P, 'revenue > 1000'), 2);
  check('countJson: WHERE + AND', addon.countJson(P, 'revenue > 1000 AND name = Bob'), 1);
  check('countJson: IN', addon.countJson(P, 'name IN (Alice, Carol)'), 2);
  checkThrows('countJson: unknown column raises', () => addon.countJson(P, 'nope = 1'));

  // aggregate
  const agg = JSON.parse(addon.aggregateJson(P, 'revenue'));
  check('aggregateJson: count', agg.count, 3);
  check('aggregateJson: sum', agg.sum, 4500);
  check('aggregateJson: min', agg.min, 500);
  check('aggregateJson: max', agg.max, 2500);
  check('aggregateJson: avg', agg.avg, 1500);
  const aggWhere = JSON.parse(addon.aggregateJson(P, 'revenue', 'revenue > 1000'));
  check('aggregateJson: composes with WHERE', aggWhere.count, 2);

  // scanArray: full
  const full = JSON.parse(addon.scanArrayJson(P));
  check('scanArrayJson: names', full.names, ['customer_id', 'name', 'revenue']);
  check('scanArrayJson: all rows, no filter', full.rows, [
    ['1', 'Alice', '500'],
    ['2', 'Bob', '1500'],
    ['3', 'Carol', '2500'],
  ]);

  // scanArray: filtered + projected + limited
  const proj = JSON.parse(
    addon.scanArrayJson(P, 'revenue > 1000', JSON.stringify(['customer_id', 'revenue']), 1)
  );
  check('scanArrayJson: filtered+projected+limited names', proj.names, ['customer_id', 'revenue']);
  check('scanArrayJson: filtered+projected+limited rows', proj.rows, [['2', '1500']]);

  // topk
  const tk = JSON.parse(addon.topkJson(P, 'revenue', 2));
  check('topkJson: 2 highest revenue, best first', tk.rows.map((r) => r[1]), ['Carol', 'Bob']);
  check('topkJson: keys are the sort values', tk.keys, [2500, 1500]);
  const tkAsc = JSON.parse(addon.topkJson(P, 'revenue', 1, null, false));
  check('topkJson: ascending', tkAsc.rows.map((r) => r[1]), ['Alice']);

  // orderBy
  const ob = JSON.parse(addon.orderByJson(P, 'revenue'));
  check('orderByJson: ascending, all rows', ob.rows.map((r) => r[1]), ['Alice', 'Bob', 'Carol']);
  const obDesc = JSON.parse(addon.orderByJson(P, 'revenue', null, true));
  check('orderByJson: descending', obDesc.rows.map((r) => r[1]), ['Carol', 'Bob', 'Alice']);
  const obWhere = JSON.parse(addon.orderByJson(P, 'revenue', 'revenue > 1000', true));
  check('orderByJson: composes with WHERE', obWhere.rows.map((r) => r[1]), ['Carol', 'Bob']);

  // streaming scan: open/next/close
  const { handle, namesJson } = addon.openScan(P, 'revenue > 1000');
  check('openScan: names', JSON.parse(namesJson), ['customer_id', 'name', 'revenue']);
  const streamed = [];
  let row;
  while ((row = addon.nextRowJson(handle)) !== null) streamed.push(JSON.parse(row));
  check('openScan/nextRowJson: streamed rows match filter', streamed, [
    ['2', 'Bob', '1500'],
    ['3', 'Carol', '2500'],
  ]);
  addon.closeScan(handle);

  // streaming scan: projected + limited
  const s2 = addon.openScan(P, null, JSON.stringify(['name']), 2);
  const rows2 = [];
  while ((row = addon.nextRowJson(s2.handle)) !== null) rows2.push(JSON.parse(row));
  check('openScan: projected + limited', rows2, [['Alice'], ['Bob']]);
  addon.closeScan(s2.handle);
} finally {
  fs.unlinkSync(P);
}

console.log(`\n${passed}/${total} N-API binding tests passed`);
process.exit(passed === total ? 0 : 1);
