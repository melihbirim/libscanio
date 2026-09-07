# Categorized benchmark snapshot

Measured locally on 2026-09-07; 200,000 input rows per format, median of
three repetitions per timing mode. Zig 0.15.2 ReleaseFast, Apache Arrow JS
21.2.0, csv-parse 7.0.2; other runtime versions appear below. These are
single-machine observations, not universal speed or memory guarantees.
See [methodology](BENCHMARKS.md#ecosystem-comparison--equivalent-workloads).

```bash
python bench/compare.py --rows 200000 --reps 3 \
  --node-modules /tmp/libscanio-bench-js/node_modules --max-rss-mb 40
```

## Results

Cold: process startup + imports + query + exit. Warm: second query after one untimed query; imports excluded. CLI warm: N/A.
Peak RSS (MiB): cold process, including runtime and imports. OS file cache is not cleared; cold means process, not disk.
Eight string columns in both formats. Engine default threading; no common thread cap. Compare within a workload only.

Versions: python=3.14.4, platform=macOS-26.5.1-arm64-arm-64bit-Mach-O, pyarrow=25.0.1, polars=1.44.1, node=v22.21.0

## CSV — 200,000 rows, 8.6 MB, WHERE cab_type = yellow

### Filtered count — scalar result, no matching table collected

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio CLI (zig) | 14.0ms | — | 2.0 MiB | 66,667 |
| libscanio Python | 38.5ms | 4.1ms | 17.4 MiB | 66,667 |
| libscanio Node | 46.0ms | 4.1ms | 41.7 MiB | 66,667 |
| PyArrow (Python) | 161.0ms | 18.8ms | 70.9 MiB | 66,667 |
| Polars (Python) | 120.6ms | 3.9ms | 83.4 MiB | 66,667 |

### Materialized Arrow — all eight string columns retained

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio Python | 111.1ms | 4.7ms | 64.3 MiB | 66,667 |
| PyArrow (Python) | 153.3ms | 27.9ms | 86.3 MiB | 66,667 |
| Polars (Python) | 170.2ms | 9.4ms | 137.6 MiB | 66,667 |
| Apache Arrow JS + CSV/JSON parser | 862.5ms | 762.6ms | 403.6 MiB | 66,667 |

### Streaming import — consume every matching field and checksum lengths

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio Python | 187.9ms | 160.0ms | 17.6 MiB | 66,667 |
| Python csv/json | 280.7ms | 254.3ms | 15.6 MiB | 66,667 |
| libscanio Node | 119.4ms | 78.4ms | 52.8 MiB | 66,667 |
| Node readline (fixture CSV/JSON) | 271.2ms | 224.6ms | 68.1 MiB | 66,667 |

## NDJSON — 200,000 rows, 30.2 MB, WHERE cab_type = yellow

### Filtered count — scalar result, no matching table collected

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio CLI (zig) | 30.3ms | — | 2.0 MiB | 66,667 |
| libscanio Python | 42.0ms | 11.8ms | 17.4 MiB | 66,667 |
| libscanio Node | 52.3ms | 11.7ms | 41.6 MiB | 66,667 |
| PyArrow (Python) | 157.3ms | 30.1ms | 95.6 MiB | 66,667 |
| Polars (Python) | 128.0ms | 11.0ms | 114.4 MiB | 66,667 |

### Materialized Arrow — all eight string columns retained

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio Python | 114.7ms | 6.9ms | 68.6 MiB | 66,667 |
| PyArrow (Python) | 166.8ms | 34.4ms | 124.6 MiB | 66,667 |
| Polars (Python) | 185.7ms | 19.5ms | 152.7 MiB | 66,667 |
| Apache Arrow JS + CSV/JSON parser | 641.0ms | 480.1ms | 397.1 MiB | 66,667 |

### Streaming import — consume every matching field and checksum lengths

| engine | cold process | warm query | cold peak RSS | rows |
|---|---|---|---|---|
| libscanio Python | 208.9ms | 180.3ms | 17.5 MiB | 66,667 |
| Python csv/json | 364.9ms | 346.8ms | 15.5 MiB | 66,667 |
| libscanio Node | 137.2ms | 95.6ms | 52.8 MiB | 66,667 |
| Node readline (fixture CSV/JSON) | 314.9ms | 260.5ms | 66.1 MiB | 66,667 |
