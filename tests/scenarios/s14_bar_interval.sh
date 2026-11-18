#!/usr/bin/env bash
# s14: interval throttling.  Two arms (bar_interval_ms=100 / =2000) on a
# uniform-flow query stretched by UNION ALL repetition; frame arrival times
# are captured by polling the growing stderr file (10ms resolution).
source "$(dirname "$BASH_SOURCE")/../common.sh"

REPEATS="${PGQP_S14_REPEATS:-12}"
ARMS=""

for i in $(seq 1 "$REPEATS"); do ARMS+="SELECT count(*), sum(x + 1) AS c FROM big_table"; [ "$i" = "$REPEATS" ] || ARMS+=" UNION ALL "; done
Q="SELECT sum(c) FROM ($ARMS) t"

run_arm() {                     # run_arm <interval_ms> <errfile>; echoes median gap ms
  local iv="$1" err="$2" t0 n prev gaps=() t
  : > "$err"
  (
    psql -X -At -c "SET pg_query_progress.bar=on" \
                 -c "SET pg_query_progress.bar_interval_ms=$iv" \
                 -c "SET max_parallel_workers_per_gather=0" \
                 -c "$Q" > /dev/null 2> "$err"
  ) &
  local pid=$!
  local -a times=()
  while kill -0 $pid 2>/dev/null; do
    n=$(grep -ac "^NOTICE" "$err" 2>/dev/null || echo 0)
    while [ "${#times[@]}" -lt "$n" ]; do times+=("$(date +%s%3N)"); done
    sleep 0.01
  done
  wait $pid
  prev=""
  for t in "${times[@]}"; do
    [ -n "$prev" ] && gaps+=($(( t - prev )))
    prev="$t"
  done
  printf '%s\n' "${gaps[@]}" | sort -n | sed -n "$(( ${#gaps[@]} / 2 + 1 ))p"
}

G100=$(run_arm 100 "$WORKDIR/s14.100.err")
G2000=$(run_arm 2000 "$WORKDIR/s14.2000.err")
F100=$(grep -ac "^NOTICE" "$WORKDIR/s14.100.err")
F2000=$(grep -ac "^NOTICE" "$WORKDIR/s14.2000.err")
echo "  info: gap100=${G100}ms gap2000=${G2000}ms frames100=$F100 frames2000=$F2000"

[ "$G100" -ge 90 ] && [ "$G100" -le 400 ]
check "100ms arm median frame gap in [~100,400]" $? "gap=${G100}ms"

# server-side gate guarantees >= 2000ms; 30ms slack absorbs the 10ms poll
# quantization of arrival-time stamping
[ "$G2000" -ge 1970 ] && [ "$G2000" -le 2600 ]
check "2000ms arm median frame gap in [~2000,2600]" $? "gap=${G2000}ms"

# interval-frame ratio: drop the immediate first frame and the terminal
# done frame (constants) from both arms
RATIO=$(awk -v a="$F100" -v b="$F2000" 'BEGIN { a-=2; b-=2; if (b<=0) print -1; else printf "%.1f", a/b }')
awk -v r="$RATIO" -v t="$PGQP_TOLERANCE" 'BEGIN { exit (r >= 20 - 6*t && r <= 20 + 6*t) ? 0 : 1 }'
check "interval frame ratio ~= 20x" $? "ratio=$RATIO ($F100 vs $F2000, minus 2 each)"

finish_scenario
