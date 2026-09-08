#!/usr/bin/env python3
"""Uploaded CSV bytes: native fast/full vs equivalent Python validation.
Fixture generation and warmup excluded; full includes rejected object creation.
Run: PYTHONPATH=python python3 bench/upload_validation.py --rows 200000 --reps 5
"""
import argparse
import csv
import io
import json
import platform
import statistics
import time
import libscanio


def python_validate(data, full):
    failed = []
    # TextIOWrapper avoids a second whole-input decoded string.
    reader = csv.reader(io.TextIOWrapper(io.BytesIO(data), encoding='utf-8', newline=''))
    next(reader)
    for row in reader:
        if float(row[1]) < 0:
            if not full:
                return False
            failed.append({'values': row, 'errors': [{'column': 1, 'column_name': 'amount',
                'rule': 'below_min', 'value': row[1]}]})
    return failed if full else True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rows', type=int, default=200000)
    p.add_argument('--reps', type=int, default=5)
    args = p.parse_args()
    if args.rows < 1 or args.reps < 1:
        p.error('rows/reps must be positive')
    assert libscanio.build_mode() == 'ReleaseFast'
    schema = {'amount': {'type': 'float', 'min': 0}}
    results = []
    for case in ('valid', 'first_invalid', 'one_percent_invalid', 'all_invalid'):
        data = ('id,amount\n' + ''.join(f'{i},{-1 if case == "all_invalid" or (case == "first_invalid" and i == 0) or (case == "one_percent_invalid" and i % 100 == 0) else 10}\n' for i in range(args.rows))).encode()
        for full in (False, True):
            native = lambda: libscanio.validate(data, schema, mode='full' if full else 'fast')
            reference = lambda: python_validate(data, full)
            assert native() == reference(), (case, full)
            samples = {'native': [], 'python': []}
            for rep in range(args.reps):
                for name, fn in ([('native', native), ('python', reference)] if rep % 2 == 0 else [('python', reference), ('native', native)]):
                    start = time.perf_counter()
                    result = fn()
                    elapsed = time.perf_counter() - start
                    samples[name].append(elapsed)
                    del result
            results.append({'case': case, 'mode': 'full' if full else 'fast',
                'median_seconds': {k: statistics.median(v) for k, v in samples.items()}, 'samples_seconds': samples})
    print(json.dumps({'rows': args.rows, 'reps': args.reps, 'platform': platform.platform(),
        'python': platform.python_version(), 'results': results}, indent=2))


if __name__ == '__main__':
    main()
