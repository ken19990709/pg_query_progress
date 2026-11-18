#!/usr/bin/env bash
# s02: runtime SQL error inside a rate-controlled query (division by zero
# on the 100th slow_outer row).  Slot must flip to failed, no residual
# running row, psql receives the original error.
source "$(dirname "$BASH_SOURCE")/../common.sh"

LOG="$WORKDIR/s2.log"
bg_open 9 s2fifo "$LOG"
# count(v) keeps the division in the target list: the planner prunes unused
# non-volatile expressions (pg_sleep survives as volatile, 1/(s.k-100) does
# not), so counting * would never raise
bg_send 9 "SELECT count(v) FROM slow_outer s, LATERAL (SELECT pg_sleep(0.02), 1/(s.k-100) AS v) sub;"

wait_until "$(timeout_scale 15)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'running'"'"' AND pid <> pg_backend_pid()" | grep -q 1'
PID=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND pid <> pg_backend_pid() LIMIT 1")

# the error fires at k=100 (about 2s in)
wait_until "$(timeout_scale 20)" "q \"SELECT 1 FROM pg_query_progress WHERE pid = $PID AND state = 'failed'\" | grep -q 1"
check "slot state is failed after runtime error" $?

sleep 1
LEFT=$(q "SELECT count(*) FROM pg_query_progress WHERE state='running' AND pid=$PID")
[ "$LEFT" = "0" ]; check "no residual running row for the session" $? "running=$LEFT"

grep -q "division by zero" "$LOG"; check "psql received the original error" $?

bg_close 9 s2fifo
finish_scenario
