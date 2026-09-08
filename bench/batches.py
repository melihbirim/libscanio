#!/usr/bin/env python3
"""Equivalent CSV row-consumption benchmark; no optional dependencies.

Requires ReleaseFast C library and Node addon. Cold = fresh process (not
cold disk); warm = second query after one untimed query. Every field and
validation error is consumed. Peak RSS includes runtime/imports; Python RSS is unavailable on Windows.
"""
import argparse
import csv
import itertools
import json
from pathlib import Path
import statistics


import subprocess
import sys
import tempfile
import time

def peak_rss_mib():
    try:
        import resource
    except ImportError:
        return None
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return rss / (1024 * 1024 if sys.platform == "darwin" else 1024)


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = {"id": {"type": "integer", "required": True},
          "score": {"type": "float", "min": 30},
          "status": {"one_of": ["new", "paid", "shipped"]},
          "email": {"required": True, "max_len": 255}}


def consume(items, validation=False, native=False):
    rows = fields = invalid = errors = error_sum = 0
    for item in items:
        row, failures = item if validation and not native else (item, [])
        values = list(row.values()) if isinstance(row, dict) else row
        rows += 1
        fields += sum(map(len, values))
        if validation and native:
            # Independent oracle for this generated fixture's four rules.
            if not values[0].strip():
                failures.append((0, "missing_required", values[0]))
            elif not values[0].strip().lstrip('+-').isdigit():
                failures.append((0, "bad_type", values[0]))
            if values[1].strip():
                try:
                    number = float(values[1])
                    if number < 30: failures.append((1, "below_min", values[1]))
                except ValueError:
                    failures.append((1, "bad_type", values[1]))
            if values[2].strip() and values[2] not in ('new', 'paid', 'shipped'):
                failures.append((2, "not_in_set", values[2]))
            if not values[3].strip(): failures.append((3, "missing_required", values[3]))
            elif len(values[3]) > 255: failures.append((3, "too_long", values[3]))
        invalid += bool(failures)
        errors += len(failures)
        for e in failures:
            column, rule, value = e if native else (e.column, e.rule, e.value)
            row_number = rows if native else e.row
            error_sum += row_number + column + len(rule) + len(value)
    return [rows, fields, invalid, errors, error_sum]


def python_run(engine, path, validation, batch_size, target_bytes):
    if engine.startswith('csv-'):
        with open(path, newline='') as f:
            if engine == 'csv-dict': reader = csv.DictReader(f)
            else:
                reader = csv.reader(f)
                next(reader)
            return consume(reader, validation, native=True)
    sys.path.insert(0, str(ROOT / 'python'))
    import libscanio as s
    if s.build_mode() != 'ReleaseFast':
        raise RuntimeError('Rebuild c-lib with -Doptimize=ReleaseFast')
    if engine == 'python-row':
        items = s.validate_iter(path, SCHEMA) if validation else s.scan(path)
    else:
        opts = dict(batch_size=batch_size, target_bytes=target_bytes, as_dict=engine == 'python-batch-dict')
        batches = s.validate_batches(path, SCHEMA, **opts) if validation else s.scan_batches(path, **opts)
        items = itertools.chain.from_iterable(batches)
    return consume(items, validation)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rows', type=int, default=200000)
    p.add_argument('--reps', type=int, default=3)
    p.add_argument('--batch-size', type=int, default=1024)
    p.add_argument('--target-bytes', type=int, default=1048576)
    p.add_argument('--json')
    p.add_argument('--worker')
    p.add_argument('--path')
    p.add_argument('--validation', action='store_true')
    p.add_argument('--warm', action='store_true')
    args = p.parse_args()
    if args.rows < 1 or args.reps < 1: p.error('rows and reps must be positive')
    if args.worker:
        run = lambda: python_run(args.worker, args.path, args.validation, args.batch_size, args.target_bytes)
        if args.warm: run()
        start = time.perf_counter()
        result = run()
        print(json.dumps({'seconds': time.perf_counter()-start, 'result': result, 'peak_rss_mib': peak_rss_mib()}))
        return
    engines = ['csv-dict', 'python-row', 'python-batch-dict', 'csv-reader', 'python-batch-tuple',
               'node-row', 'node-batch-object', 'node-batch-array']
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        path = str(Path(tmp) / 'rows.csv')
        with open(path, 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['id','score','status','email','a','b','c','d','e','f'])
            for i in range(args.rows):
                w.writerow([str(i), '20' if i % 10 == 0 else '55.5', 'paid', 'a@example.com',
                            'a','b','c','d','e','f'])
        for validation in [False, True]:
            expected = python_run('csv-reader', path, validation, args.batch_size, args.target_bytes)
            print('\n' + ('Validation + consume all fields/errors' if validation else 'Scan + consume all fields'), flush=True)
            print('| engine | cold process | warm query | cold peak RSS |\n|---|---:|---:|---:|', flush=True)
            for engine in engines:
                timings = {}
                rss_samples = []
                for warm in [False, True]:
                    samples = []
                    for _ in range(args.reps):
                        if engine.startswith('node-'):
                            cmd = ['node', str(ROOT/'bench/batches_node.js'), engine, path,
                                   str(int(validation)), str(int(warm)), str(args.batch_size), str(args.target_bytes)]
                        else:
                            cmd = [sys.executable, __file__, '--worker', engine, '--path', path,
                                   '--batch-size', str(args.batch_size), '--target-bytes', str(args.target_bytes)]
                            if validation: cmd += ['--validation']
                            if warm: cmd += ['--warm']
                        start = time.perf_counter()
                        child = subprocess.run(cmd, check=True, capture_output=True, text=True)
                        elapsed = time.perf_counter()-start
                        data = json.loads(child.stdout)
                        if data['result'] != expected:
                            raise AssertionError((engine, data['result'], expected))
                        samples.append(data['seconds'] if warm else elapsed)
                        if not warm and data.get('peak_rss_mib') is not None:
                            rss_samples.append(data['peak_rss_mib'])
                    timings['warm' if warm else 'cold'] = statistics.median(samples)
                rss = statistics.median(rss_samples) if rss_samples else None
                results.append(dict(engine=engine, validation=validation, **timings, peak_rss_mib=rss, checksum=expected))
                rss_text = f"{rss:.1f} MiB" if rss is not None else "unavailable"
                print(f"| {engine} | {timings['cold']*1000:.1f} ms | {timings['warm']*1000:.1f} ms | {rss_text} |", flush=True)
    if args.json:
        Path(args.json).write_text(json.dumps(dict(rows=args.rows,reps=args.reps,batch_size=args.batch_size,
            target_bytes=args.target_bytes,python=sys.version,node=subprocess.check_output(['node','--version'],text=True).strip(),
            platform=sys.platform,results=results), indent=2))


if __name__ == '__main__':
    main()
