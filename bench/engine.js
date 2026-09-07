// Node consumers share the same query and sink as the Python drivers.
const fs = require('fs');
const readline = require('readline');
const { performance } = require('perf_hooks');
const [engine, workload, file, fmt, timing] = process.argv.slice(2);
const fields = 'trip_id cab_type passengers distance fare tip total vendor'.split(' ');
const ls = engine === 'libscanio' ? require('../node') : null;
const arrow = engine === 'apache-arrow' ? require('apache-arrow') : null;
const parse = arrow && fmt === 'csv' ? require('csv-parse/sync').parse : null;

async function* nativeRows() {
  const stream = fs.createReadStream(file, { encoding: 'utf8' });
  const lines = readline.createInterface({ input: stream, crlfDelay: Infinity });
  let header = null;
  try {
    for await (const line of lines) {
      if (!line) continue;
      if (fmt === 'csv' && !header) { header = line.split(','); continue; }
      // This baseline supports the generated, unquoted CSV fixture only.
      const values = fmt === 'csv' ? line.split(',') : null;
      const row = fmt === 'csv'
        ? Object.fromEntries(header.map((key, i) => [key, values[i]]))
        : JSON.parse(line);
      if (row.cab_type === 'yellow') yield row;
    }
  } finally { lines.close(); stream.destroy(); }
}

async function query() {
  if (workload === 'count') return { rows: ls.count(file, 'cab_type = yellow') };
  if (workload === 'arrow') {
    const text = fs.readFileSync(file, 'utf8');
    const rows = fmt === 'csv' ? parse(text, { columns: true })
      : text.split('\n').filter(Boolean).map(JSON.parse);
    const keep = rows.filter(r => r.cab_type === 'yellow');
    const cols = Object.fromEntries(fields.map(f => [f,
      arrow.vectorFromArray(keep.map(r => r[f]), new arrow.Utf8())]));
    return arrow.tableFromArrays(cols);
  }
  const rows = ls ? ls.scan(file, { where: 'cab_type = yellow' }) : nativeRows();
  let n = 0, checksum = 0;
  for await (const row of rows) {
    n++;
    for (const f of fields) checksum += row[f].length;
  }
  return { rows: n, checksum };
}

(async () => {
  if (timing === 'warm') { await query(); if (global.gc) global.gc(); }
  const start = performance.now();
  const result = await query();
  const query_secs = (performance.now() - start) / 1000;
  const payload = workload === 'arrow'
    ? { rows: result.numRows, columns: result.numCols } : result;
  if (workload === 'arrow' && process.argv.includes('--verify'))
    payload.values = result.toArray().map(r => r.toJSON());
  process.stdout.write(JSON.stringify({ ...payload, query_secs }));
})().catch(e => { console.error(e.stack || e); process.exitCode = 1; });
