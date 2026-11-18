#!/usr/bin/env bash
# s13: basic bar rendering on the seq-scan aggregate workload.
#  - first frame query-elapsed in [gate, gate+0.5s] (gate = 500ms default;
#    elapsed is parsed from the frame's own "%.1fs" field, i.e. server-side
#    query time, not wall time)
#  - frame count >= duration/interval - 2
#  - percent sequence monotonic non-decreasing
#  - last frame "100.0% done"
#  - stdout carries no bar bytes
source "$(dirname "$BASH_SOURCE")/../common.sh"

Q="SELECT count(*), sum(x + 1) FROM big_table"
REPEATS="${PGQP_S13_REPEATS:-8}"
Q2="SELECT sum(c) FROM ("
for i in $(seq 1 "$REPEATS"); do Q2+=" SELECT count(*), sum(x + 1) AS c FROM big_table"; [ "$i" = "$REPEATS" ] || Q2+=" UNION ALL"; done
Q2+=") t"
# prefer the stretched query so the duration clears the gate even at small
# scales; fall back to the single scan when big_table is at full scale
Q="$Q2"

OUT="$WORKDIR/s13.out"; ERR="$WORKDIR/s13.err"
: > "$OUT"; : > "$ERR"

(
  T0=$(date +%s%3N)
  psql -X -At -c "SET pg_query_progress.bar=on" \
               -c "SET max_parallel_workers_per_gather=0" \
               -c "$Q" > "$OUT" 2> "$ERR"
  echo $(( $(date +%s%3N) - T0 )) > "$WORKDIR/dur"
) &
RUNPID=$!
wait "$RUNPID"
DUR_MS=$(cat "$WORKDIR/dur")
FRAMES=$(bar_count "$ERR")
echo "  info: duration=${DUR_MS}ms frames=$FRAMES"

# (1) first frame query-elapsed in [gate, gate+0.5s] (gate=500ms default)
FFE=$(bar_first_elapsed "$ERR")
awk -v e="$FFE" 'BEGIN{exit (e>=0.5 && e<=1.0)?0:1}'
check "first frame query-elapsed in [gate, gate+0.5s] (=0.5-1.0s)" $? "elapsed=${FFE}s"

# (2) frame count
MIN_FRAMES=$(( DUR_MS / 500 - 2 ))
[ "$FRAMES" -ge "$MIN_FRAMES" ] && [ "$FRAMES" -ge 2 ]
check "frame count >= duration/0.5s - 2" $? "frames=$FRAMES min=$MIN_FRAMES"

# (3) monotonic percent
MONO=$(bar_monotonic "$ERR")
[ "$MONO" = "0" ]; check "percent sequence monotonic" $? "violations=$MONO"

# (4) last frame is the done frame
bar_lastdone "$ERR"; check "last frame is '100.0% done'" $?

# (5) stdout has no bar bytes
bar_clean_stdout "$OUT"; check "stdout carries no bar bytes" $? "stdout=$(head -c 30 "$OUT")"

finish_scenario
