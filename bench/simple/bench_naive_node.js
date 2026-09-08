const fs = require('fs');
const readline = require('readline');

const path = process.argv[2];
const fmt = process.argv[3] || 'csv';
const t0 = Date.now();
let n = 0;
let header = null;
let catIdx = -1;

async function main() {
  const rl = readline.createInterface({ input: fs.createReadStream(path), crlfDelay: Infinity });
  for await (const line of rl) {
    if (fmt === 'csv') {
      if (header === null) {
        header = line.split(',');
        catIdx = header.indexOf('category');
        continue;
      }
      const fields = line.split(',');
      if (fields[catIdx] === 'B') n++;
    } else {
      if (!line.trim()) continue;
      if (JSON.parse(line).category === 'B') n++;
    }
  }
  const dt = (Date.now() - t0) / 1000;
  console.log(`rows=${n} time=${dt.toFixed(4)}s`);
}
main();
