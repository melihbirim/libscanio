const path_ = require('path');
const libscanio = require(path_.join(__dirname, '..', '..', 'node'));
const path = process.argv[2];
const t0 = Date.now();
const n = libscanio.count(path, "category = B");
const dt = (Date.now() - t0) / 1000;
console.log(`rows=${n} time=${dt.toFixed(4)}s`);
