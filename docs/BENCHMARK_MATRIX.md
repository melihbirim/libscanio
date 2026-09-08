# Historical categorized benchmark snapshot

These results predate the CPython migration. See [current Python measurements](CPYTHON_API_MIGRATION.md).

Measured locally on 2026-09-07; 200,000 input rows per format, median of
three repetitions per timing mode. Zig 0.15.2 ReleaseFast, Apache Arrow JS
21.2.0, csv-parse 7.0.2; other runtime versions appear below. These are
single-machine observations, not universal speed or memory guarantees.
See [methodology](BENCHMARKS.md#ecosystem-comparison--equivalent-workloads).

```bash
python bench/compare.py --rows 200000 --reps 3 \
  --node-modules /tmp/libscanio-bench-js/node_modules --batch-size 8192 --max-rss-mb 40
```

## Results

Cold: process startup + imports + query + exit. Warm: second query after one untimed query; imports excluded. CLI warm: N/A.
Peak RSS (MiB): cold process, including runtime and imports. OS file cache is not cleared; cold means process, not disk.
Eight string columns in both formats. Engine default threading; no common thread cap. Compare within a workload only.
Streaming batches: 8,192 rows; PyArrow batch/fragment read-ahead=0; Polars lazy=True, maintain_order=True, engine=streaming (internal buffering is engine-managed). Python consumers share the same row checksum loop.

Versions: python=3.14.4, platform=macOS-26.5.1-arm64-arm-64bit-Mach-O, pyarrow=25.0.1, polars=1.44.1, node=v22.21.0

## CSV — 200,000 rows, 8.6 MB, WHERE cab_type = yellow

### Filtered count — scalar result, no matching table collected

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio CLI (zig) | 13.4ms | — | 2.0 MiB | 66,667 |
| libscanio Python | 48.9ms | 4.1ms | 21.1 MiB | 66,667 |
| libscanio Node | 44.3ms | 4.3ms | 41.8 MiB | 66,667 |
| PyArrow (Python) | 181.7ms | 18.3ms | 72.6 MiB | 66,667 |
| Polars (Python) | 127.6ms | 3.8ms | 84.5 MiB | 66,667 |

### Materialized Arrow — all eight string columns retained

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio Python | 139.5ms | 4.4ms | 65.8 MiB | 66,667 |
| PyArrow (Python) | 181.4ms | 30.7ms | 87.7 MiB | 66,667 |
| Polars (Python) | 189.1ms | 10.5ms | 141.1 MiB | 66,667 |
| Apache Arrow JS + CSV/JSON parser | 875.2ms | 775.3ms | 404.1 MiB | 66,667 |

### Streaming import — consume every matching field and checksum lengths

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio Python | 202.8ms | 158.0ms | 21.2 MiB | 66,667 |
| PyArrow batches → Python rows | 207.4ms | 69.6ms | 84.4 MiB | 66,667 |
| Polars batches → Python rows | 205.3ms | 79.0ms | 111.0 MiB | 66,667 |
| Python csv/json | 295.7ms | 258.5ms | 19.5 MiB | 66,667 |
| libscanio Node | 117.6ms | 78.9ms | 52.7 MiB | 66,667 |
| Node readline (fixture CSV/JSON) | 289.6ms | 227.4ms | 68.3 MiB | 66,667 |

## NDJSON — 200,000 rows, 30.2 MB, WHERE cab_type = yellow

### Filtered count — scalar result, no matching table collected

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio CLI (zig) | 31.4ms | — | 2.0 MiB | 66,667 |
| libscanio Python | 58.9ms | 11.8ms | 21.1 MiB | 66,667 |
| libscanio Node | 52.1ms | 11.7ms | 41.8 MiB | 66,667 |
| PyArrow (Python) | 158.6ms | 26.6ms | 97.4 MiB | 66,667 |
| Polars (Python) | 159.4ms | 14.4ms | 115.8 MiB | 66,667 |

### Materialized Arrow — all eight string columns retained

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio Python | 121.9ms | 7.4ms | 68.7 MiB | 66,667 |
| PyArrow (Python) | 207.2ms | 42.1ms | 122.9 MiB | 66,667 |
| Polars (Python) | 195.9ms | 24.3ms | 156.2 MiB | 66,667 |
| Apache Arrow JS + CSV/JSON parser | 736.5ms | 515.7ms | 394.0 MiB | 66,667 |

### Streaming import — consume every matching field and checksum lengths

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio Python | 224.4ms | 180.8ms | 21.1 MiB | 66,667 |
| PyArrow batches → Python rows | 219.9ms | 95.4ms | 125.2 MiB | 66,667 |
| Polars batches → Python rows | 245.8ms | 86.2ms | 139.0 MiB | 66,667 |
| Python csv/json | 386.9ms | 372.2ms | 19.5 MiB | 66,667 |
| libscanio Node | 146.7ms | 93.5ms | 52.8 MiB | 66,667 |
| Node readline (fixture CSV/JSON) | 301.7ms | 266.0ms | 65.4 MiB | 66,667 |
