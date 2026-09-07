# Native validation and complete import performance

`validate()` runs a native scan and returns a report. Streaming validation
also returns every row and its failures to the host language. Optimizing
one does not remove the costs of conversion, application logic, or writing
the destination in the other.

This change:

- Parses a float once for its type and range checks. Integer syntax checks
  remain distinct so decimal input does not silently become an integer.
- Compiles `one_of` lists with at least 32 entries into an arena-owned hash
  table at schema load. Smaller lists retain linear search. A parsed schema
  must be reparsed to change membership rules; directly assembled Zig rules without
  an index still use the linear path.
- Counts every failure, while only constructing the error records retained
  by a report. Totals, failure ordering, and the retained prefix are unchanged.
  Row and batch iterators still return every error.
- Rejects impossible Gregorian dates, year zero, and timezone offsets with
  hours above 23 or minutes above 59. Datetime remains a structural validator:
  it does not consult timezone databases or verify actual leap-second events.

## Report benchmark

Before: `e0372c4`. After: this validation implementation. macOS arm64,
Python 3.14.4, Zig 0.15.2, both libraries ReleaseFast. A 500,000-row,
three-column CSV is reused; each API call opens the file and parses its
schema. One warmup is excluded. Seven timed calls per library alternate
order to reduce time drift; medians follow. File cache is not cleared.
Every report, including error order and all totals, matched the baseline.

| Schema | Before | After | Throughput ratio |
|---|---:|---:|---:|
| No rules, structural checks only | 11.46 ms | 11.79 ms | 0.97× |
| Float type + range | 21.09 ms | 16.96 ms | 1.24× |
| Four enum entries | 15.29 ms | 14.65 ms | 1.04× |
| 32 enum entries | 23.49 ms | 15.66 ms | 1.50× |
| 1,000 enum entries | 733.00 ms | 15.85 ms | 46.25× |
| Three failures per row, 100 retained errors | 26.98 ms | 23.47 ms | 1.15× |

Enum fixtures match the final list entry, so they expose linear search's
worst position. Early matches benefit less. Compiling an index has a setup
and memory cost, particularly for small files. The no-rule case was about
3% slower in this run; there is no blanket speedup claim. Tiny differences
are sensitive to the machine, code layout, and workload. These timings
measure the combined implementation on isolated rule workloads, not a
profiler's attribution of time to individual instructions.

To reproduce, preserve a baseline ReleaseFast library before rebuilding:

```sh
zig build c-lib -Doptimize=ReleaseFast
# Save the built library somewhere outside zig-out, then apply the change.
zig build c-lib -Doptimize=ReleaseFast
python3 bench/validation.py --baseline /path/to/saved/library \
  --rows 500000 --reps 7 --json report-results.json
```

Use the platform's `.dylib`, `.so`, or `.dll` file. The baseline must provide
the current binding symbols; this comparison starts at `e0372c4`.

## Complete import benchmark

This fixture has four columns, four validation rules, and 200,000 rows.
Each implementation writes accepted rows as CSV and rejected rows as JSONL
containing their original values and every failure. Native Python implements
these fixture rules independently. The output hashes match exactly: 180,000
accepted rows, 20,000 rejected rows. This is a local file import, not a
network/database load benchmark.

After one warmup, three repetitions rotate engine order. Median time includes
opening, validation, conversion, writing, and closing both output files.
Input generation and output verification are excluded. Writes use the OS
cache; there is no fsync durability guarantee in this benchmark.

| Implementation | Complete import |
|---|---:|
| Handwritten Python CSV validation | 570 ms |
| Python `validate_iter()` | 746 ms |
| Python `validate_batches()` | 539 ms |

Batches and native Python are comparable here. Native samples ranged from
512 to 623 ms and batch samples from 531 to 559 ms, so the median difference
is not a reliable superiority claim. The row iterator remains slower. Output work
and host-language object conversion can outweigh native validation gains.

```sh
zig build c-lib -Doptimize=ReleaseFast
python3 bench/import_validation.py --rows 200000 --reps 3 --json import-results.json
```

[Measurement samples and output hashes](VALIDATION_BENCHMARKS.json) accompany
this snapshot. CI runs a small import checksum test without a timing gate.
Calendar, numeric edge cases, enum lookup parity, report-cap boundaries,
and allocation cleanup are covered by core and cross-client tests.
