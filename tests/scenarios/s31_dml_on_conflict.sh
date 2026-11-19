#!/usr/bin/env bash
# s31: INSERT ... ON CONFLICT progress (attempted-row semantics).
#  - arm A, DO UPDATE + RETURNING: monotonic, terminal completed/1.0,
#    rows_returned == attempts == plan_rows (every attempt resolves to an
#    action and returns)
#  - arm B, DO NOTHING + RETURNING: monotonic, terminal completed/1.0,
#    rows_returned counts only the freshly inserted rows and is
#    strictly below plan_rows (disclosed semantics, not a bug)
source "$(dirname "$BASH_SOURCE")/../common.sh"

N=$(awk -v s="${PGQP_SCALE:-0.1}" 'BEGIN{n=int(300000*s/0.1); if(n<20000)n=20000; if(n>400000)n=400000; print n}')
HALF=$(( N / 2 ))

q "DROP TABLE IF EXISTS s31_a, s31_b" > /dev/null
for T in s31_a s31_b; do
  q "CREATE TABLE $T (k int PRIMARY KEY, v int, pad text)" > /dev/null
  q "INSERT INTO $T SELECT g, 0, repeat('x', 16) FROM generate_series(1, $HALF) g" > /dev/null
  q "ANALYZE $T" > /dev/null
done
check "conflict bases ready (prefilled=$HALF attempts=$N)" $?

run_arm() {                    # run_arm <marker> <table> <conflict-action> <pollfile>
  # leaves the terminal readout in TERM_ROW (read while the session
  # still holds the slot; closing the fifo clears it)
  local marker="$1" tbl="$2" action="$3" pollf="$4"
  TERM_ROW=""
  bg_open 9 "s31$marker" "$WORKDIR/s31.$marker.log"
  sendq 9 "SET max_parallel_workers_per_gather=0"
  sendq 9 "INSERT /* $marker */ INTO $tbl SELECT g, g, repeat('v', 64) FROM generate_series(1, $N) g ON CONFLICT (k) DO $action RETURNING k"
  local pid=""
  wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%$marker%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
    pid=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%$marker%' AND pid <> pg_backend_pid() LIMIT 1")
  [ -n "$pid" ] && poll_progress "$pid" 0.12 "$(timeout_scale 240)" "$pollf"
  TERM_ROW=$(q "SELECT state, progress, plan_rows, rows_returned FROM pg_query_progress WHERE query LIKE '%$marker%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
  bg_close 9 "s31$marker"
}

# ---- arm A: DO UPDATE -------------------------------------------------------
run_arm s31upd s31_a "UPDATE SET v = excluded.v, pad = excluded.pad" "$WORKDIR/s31.upd.poll"
analyze_polls "$WORKDIR/s31.upd.poll" armA 2 3
check "arm A (DO UPDATE): monotonic, no cc/tp collapse" $?
VA="$TERM_ROW"
echo "  info[armA]: $VA"
echo "$VA" | grep -qE "^completed\|1\|[0-9]+\|[0-9]+$"; check "arm A: terminal completed/1.0" $? "row=$VA"
PRA=$(echo "$VA" | cut -d'|' -f3); RRA=$(echo "$VA" | cut -d'|' -f4)
[ "$RRA" -ge "$N" ]; check "arm A: rows_returned == attempts" $? "returned=$RRA attempts=$N"
[ "$PRA" -ge "$N" ]; check "arm A: plan_rows approximates attempts" $? "plan_rows=$PRA attempts=$N"

# ---- arm B: DO NOTHING ------------------------------------------------------
run_arm s31nth s31_b "NOTHING" "$WORKDIR/s31.nth.poll"
analyze_polls "$WORKDIR/s31.nth.poll" armB 2 3
check "arm B (DO NOTHING): monotonic, no cc/tp collapse" $?
VB="$TERM_ROW"
echo "  info[armB]: $VB"
echo "$VB" | grep -qE "^completed\|1\|[0-9]+\|[0-9]+$"; check "arm B: terminal completed/1.0" $? "row=$VB"
PRB=$(echo "$VB" | cut -d'|' -f3); RRB=$(echo "$VB" | cut -d'|' -f4)
NEW=$(q "SELECT count(*) FROM s31_b WHERE v > 0")
[ "$NEW" = "$(( N - HALF ))" ]; check "arm B: inserted exactly the non-conflicting rows" $? "new=$NEW expected=$(( N - HALF ))"
[ "$RRB" = "$NEW" ]; check "arm B: rows_returned counts inserted rows only" $? "returned=$RRB inserted=$NEW"
[ "$PRB" -gt "$RRB" ]; check "arm B: rows_returned < plan_rows (disclosed semantics)" $? "returned=$RRB plan_rows=$PRB"

finish_scenario
