#!/usr/bin/env python3
"""Complete import benchmark: write accepted CSV and rejected JSONL rows.

Same four rules and identical output bytes for native Python, validate_iter,
validate_batches, and native validate_to_files. Timings include open/validate/write/close, not fixture
creation or output verification. Writes use the OS cache, not fsync durability.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'python'))
import libscanio as scan

NAMES = ['id', 'score', 'status', 'email']
SCHEMA = {'id': {'type':'integer', 'required':True}, 'score': {'type':'float', 'min':30},
          'status': {'one_of':['new','paid','shipped']}, 'email': {'required':True, 'max_len':255}}


def append_error(errors, row, number, column, rule):
    errors.append(dict(row=number, column=column, column_name=NAMES[column],
                       rule=rule, value=row[NAMES[column]]))


def native_rows(path):
    with open(path, newline='') as f:
        for number, row in enumerate(csv.DictReader(f), 1):
            errors = []
            value = row['id'].strip(' \t')
            body = value[1:] if value[:1] in ('+', '-') else value
            if not value: append_error(errors, row, number, 0, 'missing_required')
            elif not body.isascii() or not body.isdigit(): append_error(errors, row, number, 0, 'bad_type')
            if row['score'].strip(' \t\r\n'):
                try:
                    score = float(row['score'].strip(' \t'))
                    if not math.isfinite(score): append_error(errors, row, number, 1, 'bad_type')
                    elif score < 30: append_error(errors, row, number, 1, 'below_min')
                except ValueError:
                    append_error(errors, row, number, 1, 'bad_type')
            if row['status'].strip(' \t\r\n') and row['status'] not in ('new','paid','shipped'):
                append_error(errors, row, number, 2, 'not_in_set')
            if not row['email'].strip(' \t\r\n'): append_error(errors, row, number, 3, 'missing_required')
            elif len(row['email']) > 255: append_error(errors, row, number, 3, 'too_long')
            yield row, errors


def rows_for(engine, path):
    if engine == 'native-python':
        yield from native_rows(path)
    elif engine == 'validate_iter':
        for row, errors in scan.validate_iter(path, SCHEMA):
            yield row, [e.as_dict() for e in errors]
    else:
        for batch in scan.validate_batches(path, SCHEMA):
            for row, errors in batch:
                yield row, [e.as_dict() for e in errors]


def route(engine, source, good, bad):
    if engine == 'validate_to_files':
        stats = scan.validate_to_files(source, SCHEMA, good, bad)
        return stats['rows_valid'], stats['rows_invalid']
    accepted = rejected = 0
    with open(good, 'w', newline='', encoding='utf-8') as out, open(bad, 'w', encoding='utf-8', newline='') as rejects:
        writer = csv.DictWriter(out, fieldnames=NAMES)
        writer.writeheader()
        for row, errors in rows_for(engine, source):
            if errors:
                rejects.write(json.dumps(dict(values=list(row.values()), errors=errors), ensure_ascii=False, separators=(',', ':'))+'\n')
                rejected += 1
            else:
                writer.writerow(row)
                accepted += 1
    return accepted, rejected


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rows', type=int, default=200000)
    p.add_argument('--reps', type=int, default=3)
    p.add_argument('--json')
    args = p.parse_args()
    if args.rows < 1 or args.reps < 1: p.error('rows and reps must be positive')
    if scan.build_mode() != 'ReleaseFast': raise RuntimeError('Rebuild c-lib with -Doptimize=ReleaseFast')
    samples = {name: [] for name in ['native-python','validate_iter','validate_batches','validate_to_files']}
    with tempfile.TemporaryDirectory() as tmp:
        source, good, bad = (str(Path(tmp)/name) for name in ['source.csv','accepted.csv','rejected.jsonl'])
        with open(source, 'w', newline='') as f:
            writer = csv.writer(f); writer.writerow(NAMES)
            for i in range(args.rows):
                writer.writerow([i, '20' if i%10 == 0 else '55.5', 'paid', 'a@example.com'])
        expected = None
        for rep in range(args.reps+1):
            engines = list(samples)
            engines = engines[rep%len(engines):] + engines[:rep%len(engines)]
            for engine in engines:
                Path(good).unlink(missing_ok=True)
                Path(bad).unlink(missing_ok=True)
                start = time.perf_counter()
                counts = route(engine, source, good, bad)
                elapsed = time.perf_counter()-start
                output = [*counts, digest(good), digest(bad)]
                assert counts == (args.rows-(args.rows+9)//10, (args.rows+9)//10)
                if expected is None: expected = output
                assert output == expected, (engine, output, expected)
                if rep: samples[engine].append(elapsed)
    result = dict(rows=args.rows, reps=args.reps, output=expected,
                  seconds={name:statistics.median(values) for name,values in samples.items()},samples=samples)
    print(json.dumps(result, indent=2))
    if args.json: Path(args.json).write_text(json.dumps(result,indent=2)+'\n')


if __name__ == '__main__':
    main()
