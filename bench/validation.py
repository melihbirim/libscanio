#!/usr/bin/env python3
"""Compare native validate() before/after using two ReleaseFast libraries.

Save the old shared library before rebuilding. Pass it with --baseline.
Every result, including ordered retained errors and exact totals, must match.
Library loading and one warmup are excluded; schema parsing is included.
"""
import argparse
import ctypes
import json
from pathlib import Path
import platform
import statistics
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'python'))
import libscanio as scan
from libscanio import _loader


def snapshot(report):
    return {field: [e.as_dict() for e in report.errors] if field == 'errors'
            else getattr(report, field) for field in report.__slots__}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True)
    parser.add_argument('--rows', type=int, default=500000)
    parser.add_argument('--reps', type=int, default=9)
    parser.add_argument('--json')
    args = parser.parse_args()
    if args.rows < 1 or args.reps < 1:
        parser.error('rows and reps must be positive')
    current = _loader.load()
    baseline = ctypes.CDLL(args.baseline)
    _loader._setup_signatures(baseline)
    if baseline._handle == current._handle:
        raise RuntimeError("Baseline and current must be distinct library files")
    for lib in (baseline, current):
        if lib.scanio_build_mode() != b'ReleaseFast':
            raise RuntimeError('Both libraries must be ReleaseFast')
    scenarios = [
        ('no rules', {}, 0),
        ('float + range', {'score': {'type': 'float', 'min': 0, 'max': 100}}, 0),
        ('enum 4', {'status': {'one_of': ['new', 'shipped', 'cancelled', 'paid']}}, 0),
        ('enum 32', {'status': {'one_of': [f'v{i}' for i in range(31)] + ['paid']}}, 0),
        ('enum 1000', {'status': {'one_of': [f'v{i}' for i in range(999)] + ['paid']}}, 0),
        ('capped failures', {'score': {'min': 60}, 'status': {'one_of': ['new']},
                             'text': {'min_len': 10}}, 3),
    ]
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        path = str(Path(tmp) / 'rows.csv')
        with open(path, 'w', newline='') as f:
            f.write('score,status,text\n')
            for start in range(0, args.rows, 10000):
                f.write('55.5,paid,abc\n' * min(10000, args.rows - start))
        print('| scenario | before | after | speedup |\n|---|---:|---:|---:|', flush=True)
        for name, schema, errors_per_row in scenarios:
            reference = None
            samples = {label: [] for label in ('before', 'after')}
            for rep in range(args.reps + 1):
                order = [('before', baseline), ('after', current)]
                if rep % 2: order.reverse()
                for label, lib in order:
                    start = time.perf_counter()
                    handle = lib.scanio_validate(path.encode(), json.dumps(schema).encode(), 100)
                    if not handle:
                        raise RuntimeError(lib.scanio_last_error())
                    try:
                        raw = json.loads(lib.scanio_validate_json(handle).decode())
                    finally:
                        lib.scanio_validate_free(handle)
                    raw['errors'] = scan._validation_errors(raw['errors'])
                    report = scan.ValidationReport(**raw)
                    elapsed = time.perf_counter() - start
                    got = snapshot(report)
                    assert report.rows_total == args.rows
                    assert report.rows_invalid == (args.rows if errors_per_row else 0)
                    assert report.errors_total == args.rows * errors_per_row
                    if reference is None: reference = got
                    assert got == reference, (name, label, got, reference)
                    if rep: samples[label].append(elapsed)
            before, after = (statistics.median(samples[x]) for x in ('before', 'after'))
            results.append(dict(scenario=name, before=before, after=after, speedup=before/after,
                                samples=samples, report=reference))
            print(f'| {name} | {before*1000:.2f} ms | {after*1000:.2f} ms | {before/after:.2f}x |', flush=True)
    if args.json:
        Path(args.json).write_text(json.dumps(dict(rows=args.rows,reps=args.reps,
            platform=platform.platform(),python=sys.version,results=results),indent=2)+'\n')


if __name__ == '__main__':
    main()
