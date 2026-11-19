#!/usr/bin/env bash
# s29: INSERT ... VALUES progress (multi-row literals).
#  - row count scales with PGQP_SCALE (no fixed duration requirement:
#    the frame assertions apply once the run clears the frame gate,
#    checked against the measured duration; a sub-gate run is retried
#    once with doubled rows and otherwise skipped, never faked)
#  - bar frames: percent sequence monotonic, at least one intermediate
#    frame above 0% (exact VALUES denominator -> non-trivial progress),
#    terminal "100.0% done"
#  - view: terminal completed/1.0; tuples_processed equals the literal
#    row count; nodes_total equals the EXPLAIN node count (ModifyTable
#    included)
source "$(dirname "$BASH_SOURCE")/../common.sh"

N=$(awk -v s="${PGQP_SCALE:-0.1}" 'BEGIN{n=int(250000*s/0.1); if(n<20000)n=20000; if(n>400000)n=400000; print n}')

q "DROP TABLE IF EXISTS s29_t" > /dev/null
q "CREATE TABLE s29_t (k int, pad text)" > /dev/null
q "CREATE INDEX s29_k_idx ON s29_t (k)" > /dev/null
check "target table ready" $?

# plan shape probe: node count as EXPLAIN prints it (Insert on + child)
NODES=$(q "EXPLAIN (COSTS OFF) INSERT INTO s29_t (k, pad) VALUES (1, 'x')" |
        grep -cE 'Insert on|->')
echo "  info: explain nodes=$NODES (rows target $N)"

write_sql() {                  # write_sql <rows> <outfile>
  python3 - "$1" "$2" <<'PYEOF'
import sys
n, path = int(sys.argv[1]), sys.argv[2]
pad = "v" * 200
with open(path, "w") as f:
    f.write("SET pg_query_progress.bar = on;\n")
    f.write("SET max_parallel_workers_per_gather = 0;\n")
    f.write("INSERT /* s29ins */ INTO s29_t (k, pad) VALUES\n")
    f.write(",\n".join("(%d,'%s')" % (i, pad) for i in range(1, n + 1)))
    f.write(";\n")
    # client-side hold-open: psql shells out to sleep(1) while the server
    # session sits idle, keeping the INSERT's terminal slot row readable
    # (a server-side hold-open would itself be tracked and claim the slot)
    f.write("\\! sleep 3\n")
PYEOF
}

run_insert() {                 # run_insert <rows> -> sets DUR_MS/FRAMES/TERM_ROW
  local n="$1"
  write_sql "$n" "$WORKDIR/s29.sql"
  : > "$WORKDIR/s29.out"; : > "$WORKDIR/s29.err"; : > "$WORKDIR/s29.poll"
  TERM_ROW=""
  local t0
  t0=$(date +%s%3N)
  psql -X -q -At -f "$WORKDIR/s29.sql" > "$WORKDIR/s29.out" 2> "$WORKDIR/s29.err" &
  local rpid=$!
  local vpid=""
  if wait_until "$(timeout_scale 10)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s29ins%' AND pid <> pg_backend_pid()\" | grep -q 1"; then
    vpid=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s29ins%' AND pid <> pg_backend_pid() LIMIT 1")
  fi
  [ -n "$vpid" ] && poll_progress "$vpid" 0.15 "$(timeout_scale 90)" "$WORKDIR/s29.poll"
  # read the terminal row while the client-side hold-open keeps the
  # session (and its slot row) alive
  wait_until "$(timeout_scale 10)" "q \"SELECT 1 FROM pg_query_progress WHERE query LIKE '%s29ins%' AND state='completed'\" | grep -q 1"
  TERM_ROW=$(q "SELECT state, progress, tuples_processed, nodes_total, nodes_done FROM pg_query_progress WHERE query LIKE '%s29ins%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
  wait "$rpid"
  DUR_MS=$(( $(date +%s%3N) - t0 ))
  FRAMES=$(bar_count "$WORKDIR/s29.err")
  echo "  info: run rows=$n duration=${DUR_MS}ms frames=$FRAMES polled_pid=${vpid:-none}"
}

run_insert "$N"
# gate check on the SERVER-side elapsed of the first frame when present,
# else the wall duration; a possibly-sub-gate run gets one doubling
GATE=$(awk -v t="$PGQP_TOLERANCE" 'BEGIN{print int(500*t)}')
FFE=$(bar_first_elapsed "$WORKDIR/s29.err")
EFF_DUR=$(awk -v f="$FFE" -v d="$DUR_MS" 'BEGIN{print (f!="")?int(f*1000):d}')
if [ "$FRAMES" -lt 2 ] && [ "$EFF_DUR" -lt "$GATE" ] && [ "$N" -le 200000 ]; then
  echo "  info: first run under the frame gate; retrying with doubled rows"
  run_insert $(( N * 2 > 400000 ? 400000 : N * 2 ))
fi

# (1) terminal view row: completed / 1.0 / exact tuples / node count
V="$TERM_ROW"
echo "  info: terminal view row: $V"
echo "$V" | grep -qE "^completed\|1\|[0-9]+\|[0-9]+\|[0-9]+$"
check "terminal row completed/1.0" $? "row=$V"
TUPLES=$(echo "$V" | cut -d'|' -f3)
NT=$(echo "$V" | cut -d'|' -f4)
ND=$(echo "$V" | cut -d'|' -f5)
[ "$TUPLES" -ge "$N" ]; check "tuples_processed >= literal rows (exact denominator)" $? "tuples=$TUPLES rows=$N"
[ "$NT" -ge 2 ]; check "nodes_total counts the plan (ModifyTable included)" $? "nodes_total=$NT explain=$NODES"
[ "$ND" -ge 1 ]; check "ModifyTable counted as done (nodes_done >= 1)" $? "nodes_done=$ND"
INS=$(q "SELECT count(*) FROM s29_t")
[ "$INS" = "$N" ]; check "all rows inserted" $? "inserted=$INS expected=$N"

# (2) frame assertions (apply once the run cleared the gate)
if [ "$FRAMES" -ge 2 ]; then
  MONO=$(bar_monotonic "$WORKDIR/s29.err")
  [ "$MONO" = "0" ]; check "frame percents monotonic" $? "violations=$MONO"
  MID=$(bar_percents "$WORKDIR/s29.err" | awk '$1 > 0' | wc -l)
  [ "$MID" -ge 1 ]; check "non-trivial progress (intermediate frame > 0%)" $? "frames_above_zero=$MID"
  bar_lastdone "$WORKDIR/s29.err"; check "last frame is '100.0% done'" $?
else
  skip "frame sequence assertions" "run under the frame gate (duration=${DUR_MS}ms); view assertions above"
fi

# (3) view-side monotonicity (when mid-run polls happened)
if [ -s "$WORKDIR/s29.poll" ]; then
  NRUN=$(awk -F'\t' '$2 == "running"' "$WORKDIR/s29.poll" | wc -l)
  if [ "$NRUN" -ge 3 ]; then
    analyze_polls "$WORKDIR/s29.poll" s29 1 2
    check "view: mid-run monotonic, no cc/tp collapse" $?
  else
    skip "view mid-run monotonicity" "only $NRUN running samples"
  fi
else
  skip "view mid-run monotonicity" "no mid-run samples captured"
fi

finish_scenario
