#!/usr/bin/env bash
# bench_lambda_tiers.sh — libscanio vs pyarrow under simulated AWS Lambda
# memory ceilings (docker --memory=), the real deployment shape a Lambda
# function processing an S3-triggered CSV file actually runs under.
#
# Lambda bills per GB-second and locks a function into a fixed memory
# tier — "does this fit in the cheap tier" is a real dollar question,
# not an abstract ratio. See ROADMAP.md's "AWS Lambda memory-tier
# scenario" entry for the real numbers this produced and one retracted
# finding caught before it got published.
#
# Usage:
#   ./bench/lambda/bench_lambda_tiers.sh <csv_file> <where_clause> [tier ...]
#   ./bench/lambda/bench_lambda_tiers.sh /tmp/bench_50mb.csv "status = completed"
#   ./bench/lambda/bench_lambda_tiers.sh data.csv "nmbr > 10 AND str = x" 128m 256m 512m
#
# Default tiers if none given: 128m 256m 512m 1024m (Lambda's own common
# console presets). WHERE syntax: "col OP val [AND col OP val ...]",
# same as libscanio's Python binding — see run_pyarrow.py's own comment
# for exactly what subset it supports.
#
# Needs: docker, and this must be run from the repo root (builds the
# image with repo root as context — see Dockerfile's own comment).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE="libscanio-lambda-bench"

CSV="${1:?usage: bench_lambda_tiers.sh <csv_file> <where_clause> [tier ...]}"
WHERE="${2:?usage: bench_lambda_tiers.sh <csv_file> <where_clause> [tier ...]}"
shift 2
TIERS=("$@")
[ ${#TIERS[@]} -eq 0 ] && TIERS=(128m 256m 512m 1024m)

CSV="$(cd "$(dirname "$CSV")" && pwd)/$(basename "$CSV")"
DATA_DIR="$(dirname "$CSV")"
CSV_NAME="$(basename "$CSV")"

command -v docker >/dev/null || { echo "docker not found on PATH"; exit 1; }
[ -f "$CSV" ] || { echo "CSV not found: $CSV"; exit 1; }

echo "Building $IMAGE (arm64 — see Dockerfile comment for x86_64)..."
docker build -f "$SCRIPT_DIR/Dockerfile" -t "$IMAGE" "$ROOT" --platform linux/arm64 >/dev/null

# Correctness first, unconstrained, before trusting any tier's timing.
echo
echo "Correctness check (no memory limit):"
c_out=$(docker run --rm -v "$DATA_DIR:/data:ro" "$IMAGE" python3 /bench/run_libscanio.py "/data/$CSV_NAME" "$WHERE")
p_out=$(docker run --rm -v "$DATA_DIR:/data:ro" "$IMAGE" python3 /bench/run_pyarrow.py "/data/$CSV_NAME" "$WHERE")
echo "  libscanio: $c_out"
echo "  pyarrow:   $p_out"
c_rows=$(echo "$c_out" | grep -oE 'rows=[0-9]+' | cut -d= -f2)
p_rows=$(echo "$p_out" | grep -oE 'rows=[0-9]+' | cut -d= -f2)
if [ "$c_rows" != "$p_rows" ]; then
    echo "  MISMATCH: libscanio=$c_rows rows, pyarrow=$p_rows rows — not publishing tier results for a query the two engines don't agree on."
    exit 1
fi
echo "  match: $c_rows rows both engines"

echo
printf "%-8s %-12s %10s %10s %10s\n" tier engine result time peakMB
for mem in "${TIERS[@]}"; do
    for engine in libscanio pyarrow; do
        out=$(docker run --rm --memory="$mem" -v "$DATA_DIR:/data:ro" "$IMAGE" python3 "/bench/run_${engine}.py" "/data/$CSV_NAME" "$WHERE" 2>&1) || true
        if echo "$out" | grep -q "^OK"; then
            t=$(echo "$out" | grep -oE 'time=[0-9.]+s' | cut -d= -f2)
            m=$(echo "$out" | grep -oE 'peak_rss=[0-9.]+MB' | cut -d= -f2)
            printf "%-8s %-12s %10s %10s %10s\n" "$mem" "$engine" "OK" "$t" "$m"
        else
            printf "%-8s %-12s %10s %10s %10s\n" "$mem" "$engine" "OOM/FAIL" "-" "-"
        fi
    done
done
