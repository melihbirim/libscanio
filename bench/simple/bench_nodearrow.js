const fs = require('fs');
const { parse } = require('csv-parse/sync');
const { tableFromArrays } = require('apache-arrow');

const path = process.argv[2];
const fmt = process.argv[3] || 'csv';
const t0 = Date.now();

let category;
if (fmt === 'csv') {
  const content = fs.readFileSync(path);
  const records = parse(content, { columns: true });
  category = new Array(records.length);
  for (let i = 0; i < records.length; i++) category[i] = records[i].category;
} else {
  const lines = fs.readFileSync(path, 'utf8').split('\n').filter(l => l.trim());
  category = new Array(lines.length);
  for (let i = 0; i < lines.length; i++) category[i] = JSON.parse(lines[i]).category;
}

const table = tableFromArrays({ category });
let n = 0;
const col = table.getChild('category');
for (let i = 0; i < col.length; i++) if (col.get(i) === 'B') n++;

const dt = (Date.now() - t0) / 1000;
console.log(`rows=${n} time=${dt.toFixed(4)}s`);
