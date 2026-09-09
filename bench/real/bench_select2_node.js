const path_ = require('path');
const libscanio = require(path_.join(__dirname, '..', '..', 'node'));
const path = process.argv[2];
const t0 = Date.now();
const rows = libscanio.scanArray(path, { columns: ["trip_id", "fare_amount"], where: "rate_code_id = 6" });
const dt = (Date.now() - t0) / 1000;
console.log(`rows=${rows.length} time=${dt.toFixed(4)}s`);
