'use strict';
const s = require('../node');
const addon = require('../zig-out/lib/scanio.node');
// Addon gets its own build-mode check; a ReleaseFast C library is not proof.
if (addon.buildMode() !== 'ReleaseFast') throw new Error('Rebuild node with -Doptimize=ReleaseFast');
const [engine, path, validationArg, warmArg, size, bytes] = process.argv.slice(2);
const validation = validationArg === '1';
const schema = {id:{type:'integer',required:true},score:{type:'float',min:30},
  status:{one_of:['new','paid','shipped']},email:{required:true,max_len:255}};
async function run() {
  const totals = [0,0,0,0,0];
  function consume(item) {
    const row = validation ? item.row : item;
    const errors = validation ? item.errors : [];
    totals[0]++;
    for (const value of Object.values(row)) totals[1] += value.length;
    totals[2] += Number(errors.length > 0);
    totals[3] += errors.length;
    for (const e of errors) totals[4] += e.row + e.column + e.rule.length + e.value.length;
  }
  if (engine === 'node-row') {
    for await (const item of (validation ? s.validateIter(path,schema) : s.scan(path))) consume(item);
  } else {
    const opts = {batchSize:Number(size),targetBytes:Number(bytes),asObjects:engine==='node-batch-object'};
    for await (const batch of (validation ? s.validateBatches(path,schema,opts) : s.scanBatches(path,opts))) {
      for (const item of batch) consume(item);
    }
  }
  return totals;
}
(async()=>{
  if(warmArg==='1') await run();
  const start=performance.now();
  const result=await run();
  console.log(JSON.stringify({seconds:(performance.now()-start)/1000,result,peak_rss_mib:process.resourceUsage().maxRSS/1024}));
})().catch(e=>{console.error(e);process.exit(1);});
