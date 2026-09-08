"""200K scan benchmark. Set SCANIO_BASELINE_PACKAGE to the old package parent.
Run with a ReleaseFast in-place extension on macOS/Linux.
"""
import csv,io,itertools,json,os,resource,sys,time
from pathlib import Path
ROOT=str(Path(__file__).resolve().parents[1])
if len(sys.argv)>1:
    engine,workload,path=sys.argv[1:]
    if engine=='cpython':
        sys.path.insert(0,ROOT+'/python')
        import libscanio
        assert libscanio.build_mode()=='ReleaseFast'
    if engine=='ctypes_baseline':
        sys.path.insert(0,os.environ['SCANIO_BASELINE_PACKAGE'])
        import libscanio
        assert libscanio.build_mode()=='ReleaseFast'
    def batches():
        if engine in ('cpython','ctypes_baseline'):yield from libscanio.scan_batches(path,batch_size=1024,as_dict=False)
        else:
            with open(path,encoding='utf-8',newline='') as f:
                reader=csv.reader(f);next(reader)
                while True:
                    batch=list(map(tuple,itertools.islice(reader,1024)))
                    if not batch:break
                    yield batch
    start=time.perf_counter_ns()
    if workload=='stream':
        count=checksum=0
        for batch in batches():
            count+=len(batch)
            checksum+=sum(len(v) for row in batch for v in row)
    else:
        if engine in ('cpython','ctypes_baseline'): rows=libscanio.scan_array(path)
        else:
            rows=[]
            for batch in batches():rows.extend(batch)
    elapsed=(time.perf_counter_ns()-start)/1e6
    peak=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/(1048576 if sys.platform == "darwin" else 1024)
    # Full ordered-content verification occurs outside timing/RSS measurement.
    import hashlib
    if workload=='stream':rows=[row for batch in batches() for row in batch]
    digest=hashlib.sha256(json.dumps(rows,ensure_ascii=False,separators=(',',':')).encode()).hexdigest()
    print(json.dumps(dict(ms=elapsed,peak_mib=peak,rows=len(rows),digest=digest)))
else:
    import subprocess,tempfile,statistics,platform
    results=[]
    with tempfile.TemporaryDirectory() as td:
        path=Path(td)/'input.csv'
        with path.open('w',encoding='utf-8',newline='') as f:
            w=csv.writer(f);w.writerow(['id','amount','city','note'])
            for i in range(200000):w.writerow([i,f'{i%1000}.50','London' if i%2 else 'İstanbul','hello, café "quoted"' if i%10==0 else 'ordinary'])
        for workload in ['stream','materialize']:
            samples={e:[] for e in ['cpython','ctypes_baseline','python']}
            for rep in range(5):
                order=['cpython','ctypes_baseline','python'];order=order[rep%3:]+order[:rep%3]
                for engine in order:samples[engine].append(json.loads(subprocess.check_output([sys.executable,__file__,engine,workload,str(path)])))
            assert {r['rows'] for v in samples.values() for r in v}=={200000}
            assert len({r['digest'] for v in samples.values() for r in v})==1
            medians={e:{k:statistics.median(r[k] for r in v) for k in ['ms','peak_mib']} for e,v in samples.items()}
            results.append(dict(workload=workload,medians=medians,samples=samples))
            print(workload,medians,flush=True)
        output=dict(rows=200000,columns=4,input_bytes=path.stat().st_size,reps=5,platform=platform.platform(),python=platform.python_version(),results=results)
    Path('cpython-scan-results.json').write_text(json.dumps(output,indent=2))
