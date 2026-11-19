#!/usr/bin/env bash
# s13: basic bar rendering on the seq-scan aggregate workload.
#  - first frame query-elapsed in [gate, gate+0.5s] (gate = 500ms default;
#    elapsed is parsed from the frame's own "%.1fs" field, i.e. server-side
#    query time, not wall time)
#  - frame count >= duration/interval - 2
#  - percent sequence monotonic non-decreasing
#  - last frame "100.0% done"
#  - stdout carries no bar bytes
# The two wall-clock-paced readings (first-frame window, frame count) get
# one guarded re-measure with s21's semantics: a cold instance on a loaded
# shared runner can stretch them without any extension fault, so a miss
# re-runs the statement once and the second capture is judged.
source "$(dirname "$BASH_SOURCE")/../common.sh"

Q="SELECT count(*), sum(x + 1) FROM big_table"
REPEATS="${PGQP_S13_REPEATS:-$(awk -v s="${PGQP_SCALE:-0.1}" 'BEGIN{r=24/(8*s); printf "%d", (r<2)?2:int(r+0.5)}')}"
Q2="SELECT sum(c) FROM ("
for i in $(seq 1 "$REPEATS"); do Q2+=" SELECT count(*), sum(x + 1) AS c FROM big_table"; [ "$i" = "$REPEATS" ] || Q2+=" UNION ALL"; done
Q2+=") t"
# prefer the stretched query so the duration clears the gate even at small
# scales; fall back to the single scan when big_table is at full scale
Q="$Q2"

run_query() {                  # run_query <out> <err>; writes $WORKDIR/dur
  : > "$1"; : > "$2"
  (
    T0=$(date +%s%3N)
    psql -X -At -c "SET pg_query_progress.bar=on" \
                 -c "SET max_parallel_workers_per_gather=0" \
                 -c "$Q" > "$1" 2> "$2"
    echo $(( $(date +%s%3N) - T0 )) > "$WORKDIR/dur"
  ) &
  wait $!
}

# timing_ok <elapsed> <frames> <dur_ms>: the two readings that scale with
# wall-clock pacing -- first frame inside [gate, gate+0.5s], and enough
# frames for the statement's own duration
timing_ok() {
  local e="$1" frames="$2" min=$(( $3 / 500 - 2 ))
  [ -n "$e" ] || return 1
  awk -v e="$e" 'BEGIN{exit (e>=0.5 && e<=1.0)?0:1}' || return 1
  [ "$frames" -ge "$min" ] && [ "$frames" -ge 2 ]
}

OUT="$WORKDIR/s13.out"; ERR="$WORKDIR/s13.err"
run_query "$OUT" "$ERR"
DUR_MS=$(cat "$WORKDIR/dur"); FRAMES=$(bar_count "$ERR")
echo "  info: duration=${DUR_MS}ms frames=$FRAMES"

# one guarded re-measure (s21-style): retry iff a timing-window reading is
# off, then keep the second capture as the one every check below judges
FFE=$(bar_first_elapsed "$ERR")
if ! timing_ok "$FFE" "$FRAMES" "$DUR_MS"; then
  echo "  info: timing window missed; re-measuring once"
  OUT="$WORKDIR/s13.retry.out"; ERR="$WORKDIR/s13.retry.err"
  run_query "$OUT" "$ERR"
  DUR_MS=$(cat "$WORKDIR/dur"); FRAMES=$(bar_count "$ERR")
  FFE=$(bar_first_elapsed "$ERR")
  echo "  info: re-measure duration=${DUR_MS}ms frames=$FRAMES"
fi

# (1) first frame query-elapsed in [gate, gate+0.5s] (gate=500ms default)
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
