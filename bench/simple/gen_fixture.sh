#!/usr/bin/env bash
# gen_fixture.sh <rows> <outfile>
set -euo pipefail
ROWS="$1"
OUT="$2"
awk -v rows="$ROWS" 'BEGIN{
  print "id,category,amount";
  split("A,B,C,D,E",cats,",");
  for(i=1;i<=rows;i++){
    printf "%d,%s,%.2f\n", i, cats[(i%5)+1], (i*37)%10000/100;
  }
}' > "$OUT"
