"""Runs inside the lambda-bench container. Usage:
    python3 run_pyarrow.py <csv_path> <where_clause>
Same WHERE syntax as libscanio's own ("col OP val [AND col OP val ...]")
so both scripts take the identical argument — parsed here into pyarrow
compute filters instead of libscanio's C ABI predicates. Only what this
bench needs: =, !=, >, >=, <, <=, ANDed. Values compared as int if they
parse as one (matches the mixed int/string columns real fixtures use),
else as string.
"""
import sys, time, resource, operator
import pyarrow.dataset as ds
import pyarrow.compute as pc

path, where = sys.argv[1], sys.argv[2]

OPS = {
    "=": operator.eq, "!=": operator.ne,
    ">=": operator.ge, "<=": operator.le,
    ">": operator.gt, "<": operator.lt,
}


def parse_value(v: str):
    try:
        return int(v)
    except ValueError:
        return v


def build_filter(where: str):
    expr = None
    for clause in where.split(" AND "):
        parts = clause.strip().split()
        col, op, val = parts[0], parts[1], " ".join(parts[2:])
        cond = OPS[op](pc.field(col), parse_value(val))
        expr = cond if expr is None else (expr & cond)
    return expr


t0 = time.time()
d = ds.dataset(path, format="csv")
tbl = d.to_table(filter=build_filter(where))
dt = time.time() - t0
peak_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
print(f"OK rows={tbl.num_rows} time={dt:.3f}s peak_rss={peak_mb:.1f}MB")
