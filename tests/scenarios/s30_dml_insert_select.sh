#!/usr/bin/env bash
# s30: INSERT ... SELECT progress over a table-scan source (the F2 form).
#
# Planner fact this scenario also pins down: parallel mode is enabled only
# for top-level SELECT statements (the planner's parallelModeOK gate),
# so the source subtree of an INSERT never grows a Gather on any
# supported major -- the plan is Insert on ... over a plain scan.  The
# assertion of "no Gather" documents that; if a future major allows
# parallel DML sources, it flips and the worker-merge-under-ModifyTable
# path needs a dedicated scenario.
#
#  - view: monotonic with enough distinct values, no mid-run collapse,
#    terminal completed/1.0
#  - no-RETURNING readouts (disclosed semantics): plan_rows = 0 and
#    rows_returned = 0 while progress itself is driven by the source
#  - all source rows land
source "$(dirname "$BASH_SOURCE")/../common.sh"

psql -X -q -v ON_ERROR_STOP=1 -v scale="${PGQP_SCALE:-0.1}" -f "$TESTS_DIR/setup.sql" > /dev/null 2>&1
check "workload tables ready" $?

q "DROP TABLE IF EXISTS s30_t" > /dev/null
q "CREATE TABLE s30_t (x int, y int)" > /dev/null
TOTAL=$(q "SELECT count(*) FROM big_table")

FORCEPAR="SET max_parallel_workers_per_gather=2; SET min_parallel_table_scan_size=0; SET parallel_setup_cost=1; SET parallel_tuple_cost=0.0000001"

EX=$(q "$FORCEPAR; EXPLAIN (COSTS OFF) INSERT /* s30ins */ INTO s30_t SELECT x, y FROM big_table")
echo "$EX" | grep -q "Insert on"
check "plan top node is Insert on" $?
echo "$EX" | grep -q "Seq Scan on big_table"
check "source plan is a table scan" $?
if echo "$EX" | grep -q "Gather"; then
  check "source plan has no Gather (parallel DML sources unplannable today)" 1 "$EX"
else
  check "source plan has no Gather (parallel DML sources unplannable today)" 0
fi

LOG="$WORKDIR/s30.log"
bg_open 9 s30fifo "$LOG"
sendq 9 "$FORCEPAR"
sendq 9 "INSERT /* s30ins */ INTO s30_t SELECT x, y FROM big_table"

PID=""
wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s30ins%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
  PID=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s30ins%' AND pid <> pg_backend_pid() LIMIT 1")
[ -n "$PID" ]; check "leader row visible while running" $? "pid=${PID:-none}"

POLLF="$WORKDIR/s30.poll"
if [ -n "$PID" ]; then
  poll_progress "$PID" 0.12 "$(timeout_scale 240)" "$POLLF"
fi
# terminal readouts read while the fifo session still holds the slot
TR=$(q "SELECT state, progress, plan_rows, rows_returned, parallel FROM pg_query_progress WHERE query LIKE '%s30ins%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
bg_close 9 s30fifo

analyze_polls "$POLLF" s30 3 5
check "monotonic, >=5 distinct progress values, no cc/tp collapse" $?

echo "  info: terminal row: $TR"
ST=$(echo "$TR" | cut -d'|' -f1); PR=$(echo "$TR" | cut -d'|' -f2)
PLR=$(echo "$TR" | cut -d'|' -f3); RRE=$(echo "$TR" | cut -d'|' -f4)
PAR=$(echo "$TR" | cut -d'|' -f5)
[ "$ST" = "completed" ] && [ "$PR" = "1" ]
check "terminal completed/1.0" $? "row=$TR"
[ "$PLR" = "0" ]; check "no-RETURNING readout: plan_rows = 0 (planner prices ModifyTable output at 0)" $? "plan_rows=$PLR"
[ "$RRE" = "0" ]; check "no-RETURNING readout: rows_returned = 0" $? "rows_returned=$RRE"
[ "$PAR" = "f" ]; check "parallel = f (serial DML source, as planned)" $? "parallel=$PAR"

INS=$(q "SELECT count(*) FROM s30_t")
[ "$INS" = "$TOTAL" ]; check "all source rows inserted" $? "inserted=$INS source=$TOTAL"

finish_scenario
