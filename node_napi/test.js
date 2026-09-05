// Real test for the N-API addon — no mocks. Loads zig-out/lib/scanio.node
// (dev build) directly, same as a real consumer would in development.
// This is the replacement path for the koffi-based node/ package (see
// src/node_binding.zig's doc comment for why) — starting with just
// schemaJson() to prove the whole Zig-core -> N-API -> JS pipeline works
// on every platform, Windows included, before porting the rest of
// node/'s API surface onto it.
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

const p = path.join(os.tmpdir(), `libscanio_napi_test_${process.pid}.csv`);
fs.writeFileSync(p, 'customer_id,name,revenue\n1,Alice,500\n2,Bob,1500\n');

try {
  check('schemaJson returns the real column names, in order', JSON.parse(addon.schemaJson(p)), [
    'customer_id',
    'name',
    'revenue',
  ]);

  checkThrows('schemaJson on a missing file throws', () => addon.schemaJson('/does/not/exist_12345.csv'));
} finally {
  fs.unlinkSync(p);
}

console.log(`\n${passed}/${total} N-API binding tests passed`);
process.exit(passed === total ? 0 : 1);
