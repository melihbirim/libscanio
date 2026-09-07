"""One Python engine invocation; stdout is a machine-readable result."""
import csv
import gc
import json
import os
import sys
import time

engine, workload, path, fmt, timing = sys.argv[1:6]
verify = "--verify" in sys.argv[6:]
fields = "trip_id cab_type passengers distance fare tip total vendor".split()
where = "cab_type = yellow"
if engine == "libscanio":
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))
    import libscanio as ls
    ls.build_mode()  # Load the native library before the warm query timer.
if engine == "pyarrow" or workload == "arrow":
    import pyarrow as pa
if engine == "pyarrow":
    import pyarrow.dataset as ds
    import pyarrow.compute as pc
    import pyarrow.csv as pacsv
if engine == "polars":
    import polars as pl


def native_rows():
    with open(path, newline="", encoding="utf-8") as f:
        rows = csv.DictReader(f) if fmt == "csv" else (json.loads(l) for l in f if l.strip())
        yield from (r for r in rows if r["cab_type"] == "yellow")


def query():
    if engine == "libscanio":
        if workload == "count":
            return ls.count(path, where)
        if workload == "arrow":
            return ls.scan_table(path, where=where, infer_types=False)
        rows = ls.scan(path, where=where)
    elif engine == "polars":
        schema = dict.fromkeys(fields, pl.String)
        lf = (pl.scan_csv(path, schema=schema) if fmt == "csv"
              else pl.scan_ndjson(path, schema=schema))
        lf = lf.filter(pl.col("cab_type") == "yellow")
        if workload == "count":
            return lf.select(pl.len()).collect(engine="streaming").item()
        # Conversion is part of the timed operation: all three APIs
        # deliver an Arrow table, not engine-specific intermediate data.
        return lf.collect(engine="streaming").to_arrow()
    elif engine == "pyarrow":
        schema = pa.schema([(f, pa.string()) for f in fields])
        file_format = (ds.CsvFileFormat(convert_options=pacsv.ConvertOptions(
            column_types=schema)) if fmt == "csv" else ds.JsonFileFormat())
        dataset = ds.dataset(path, format=file_format, schema=schema)
        predicate = pc.field("cab_type") == "yellow"
        if workload == "count":
            return dataset.count_rows(filter=predicate)
        return dataset.to_table(filter=predicate)
    else:
        rows = native_rows()
    n = checksum = 0
    for row in rows:
        n += 1
        # Same sink in both Python implementations; every selected field
        # is consumed. Fixtures are ASCII, so lengths also equal bytes.
        checksum += sum(len(row[f]) for f in fields)
    return {"rows": n, "checksum": checksum}


if timing == "warm":
    warmup = query()
    del warmup
    gc.collect()
start = time.perf_counter()
result = query()
secs = time.perf_counter() - start
payload = {"query_secs": secs}
if workload == "arrow":
    assert result.column_names == fields
    assert all(pa.types.is_string(f.type) or pa.types.is_large_string(f.type)
               for f in result.schema), result.schema
    payload.update(rows=result.num_rows, columns=result.num_columns)
    if verify:
        payload["values"] = result.to_pylist()
elif workload == "count":
    payload["rows"] = result
else:
    payload.update(result)
print(json.dumps(payload))
