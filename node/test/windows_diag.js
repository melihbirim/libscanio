// Temporary diagnostic for the Windows koffi crash on scanio_open() —
// see ROADMAP.md's M5b entry. Isolates whether koffi is broken for ANY
// call on this runner, or specifically for scanio_open()'s signature
// (str + struct pointer, void* return), and whether passing a real
// null pointer instead of a fully-populated options struct changes
// anything.
const path = require('path');
const os = require('os');
const fs = require('fs');
const { load } = require('../lib/loader.js');

const { fns } = load();

console.log('[diag] step 1: scanio_last_error() — zero args, str return');
const err = fns.scanio_last_error();
console.log('[diag] step 1 OK:', JSON.stringify(err));

const csvPath = path.join(os.tmpdir(), `libscanio_diag_${process.pid}.csv`);
fs.writeFileSync(csvPath, 'a,b\n1,2\n');
console.log('[diag] step 2: scanio_open(path, null) — real null pointer, not NO_OPTIONS struct');
const ctx1 = fns.scanio_open(csvPath, null);
console.log('[diag] step 2 OK:', ctx1);

console.log('[diag] step 3: scanio_open(path, NO_OPTIONS) — the known-crashing case');
const NO_OPTIONS = { columns: null, n_columns: 0, where: null, n_where: 0, limit: -1n, max_column: -1n };
const ctx2 = fns.scanio_open(csvPath, NO_OPTIONS);
console.log('[diag] step 3 OK:', ctx2);

console.log('[diag] all steps completed');
