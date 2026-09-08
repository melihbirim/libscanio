#!/usr/bin/env bash
# run_bench_all.sh <fixture> <label> <fmt: csv|json> <reps>
set -uo pipefail
SCRATCH="$(cd "$(dirname "$0")" && pwd)"
FILE="$1"
LABEL="$2"
FMT="$3"
REPS="${4:-3}"

run_n() {
  local n="$1"; shift
  local cmd=("$@")
  local times=() rss=()
  for ((i=0; i<n; i++)); do
    out=$(/usr/bin/time -l "${cmd[@]}" 2>&1)
    if ! echo "$out" | grep -q "rows="; then
      echo "CRASH/ERROR"
      return
    fi
    t=$(echo "$out" | grep -o 'time=[0-9.]*s' | grep -o '[0-9.]*')
    r=$(echo "$out" | grep 'maximum resident set size' | awk '{print $1}')
    rows=$(echo "$out" | grep -o 'rows=[0-9]*' | grep -o '[0-9]*')
    times+=("$t")
    rss+=("$r")
  done
  local mid=$(( (n+1) / 2 ))
  t_med=$(printf '%s\n' "${times[@]}" | sort -n | sed -n "${mid}p")
  r_med=$(printf '%s\n' "${rss[@]}" | sort -n | sed -n "${mid}p")
  r_mb=$(echo "scale=2; $r_med/1048576" | bc)
  echo "rows=$rows time=${t_med}s rss=${r_mb}MB"
}

SIZE=$(ls -la "$FILE" | awk '{print $5}')
echo "=== $LABEL / $FMT ($FILE, $SIZE bytes), $REPS reps ==="
echo -n "libscanio-python: "; run_n "$REPS" python3 "$SCRATCH/bench_py.py" "$FILE"
echo -n "libscanio-node:   "; run_n "$REPS" node "$SCRATCH/bench_node.js" "$FILE"
echo -n "naive-python:     "; run_n "$REPS" python3 "$SCRATCH/bench_naive_py.py" "$FILE" "$FMT"
echo -n "naive-node:       "; run_n "$REPS" node "$SCRATCH/bench_naive_node.js" "$FILE" "$FMT"
echo -n "pyarrow:          "; run_n "$REPS" python3 "$SCRATCH/bench_pyarrow.py" "$FILE" "$FMT"
echo -n "nodearrow:        "; run_n "$REPS" node "$SCRATCH/bench_nodearrow.js" "$FILE" "$FMT"
echo -n "pandas:           "; run_n "$REPS" python3 "$SCRATCH/bench_pandas.py" "$FILE" "$FMT"
echo -n "polars:           "; run_n "$REPS" python3 "$SCRATCH/bench_polars.py" "$FILE" "$FMT"
echo -n "duckdb:           "; run_n "$REPS" python3 "$SCRATCH/bench_duckdb.py" "$FILE" "$FMT"
