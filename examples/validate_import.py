"""Validating an import — the "score must be a number over 30" case.

Run:  python3 examples/validate_import.py
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))

import libscanio

PATH = os.path.join(os.path.dirname(__file__), "scores.csv")

# One rule, two halves: `type` says what shape the cell must be, `min`
# says how big. They are separate on purpose — `min` alone would still
# reject "abc", but saying `type` makes the intent explicit and gives a
# `bad_type` error instead of a confusing range one.
#
# `float` here means "any usable number", integers included. Use
# `integer` only if a decimal point should itself be an error.
#
# NOTE: `min` is INCLUSIVE. `min: 30` means >= 30, so a score of exactly
# 30 passes. For strictly greater than 30 on integer data, use min: 31.
SCHEMA = {"score": {"type": "float", "min": 30}}


def main() -> int:
    # ── 1. The summary: one pass, bounded memory, no rows returned ──
    report = libscanio.validate_report(PATH, SCHEMA)
    print(f"{report.rows_valid} of {report.rows_total} rows loadable")
    for e in report.errors:
        print(f"  row {e.row}  {e.column_name}={e.value!r}  {e.rule}")

    print()
    print("failures by rule:", report.counts)
    print("ok:", report.ok)

    # ── 2. The stream: each row WITH its failures, so both halves of
    #      the import can be written in the same pass ──
    print()
    loaded, rejected = 0, []
    for row, errors in libscanio.validate_iter(PATH, SCHEMA):
        if errors:
            rejected.append((row, errors))
        else:
            loaded += 1  # ...in real life: insert into the target table
    print(f"loaded {loaded}, rejected {len(rejected)}")
    for row, errors in rejected:
        why = ", ".join(f"{e.rule}({e.value!r})" for e in errors)
        print(f"  id={row['id']}: {why}")

    # ── 3. No schema yet? Draft one from the file and edit it ──
    print()
    print("inferred draft:", libscanio.infer_schema(PATH))
    return 0 if report.ok else 1


if __name__ == "__main__":
    sys.exit(main())
