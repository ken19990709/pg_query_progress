#!/usr/bin/env bash
# s08: parallel query -- leader-only view row with parallel=t, no crash,
# final 1.0.
source "$(dirname "$BASH_SOURCE")/../common.sh"

LOG="$WORKDIR/s8.log"
bg_open 9 s8fifo "$LOG"
bg_send 9 "SET max_parallel_workers_per_gather = 4;"
bg_send 9 "SELECT count(*), sum(x+1) FROM big_table;"

wait_until "$(timeout_scale 30)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'running'"'"' AND pid <> pg_backend_pid() AND query LIKE '"'"'%sum(x+1)%'"'"'" | grep -q 1'
check "parallel query tracked running" $?

PAR=$(q "SELECT parallel FROM pg_query_progress WHERE state='running' AND query LIKE '%sum(x+1)%' LIMIT 1")
[ "$PAR" = "t" ]; check "parallel flag is true" $? "parallel=$PAR"

wait_until "$(timeout_scale 120)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'completed'"'"' AND query LIKE '"'"'%sum(x+1)%'"'"'" | grep -q 1'
check "parallel query completed (no crash)" $?
P=$(q "SELECT progress FROM pg_query_progress WHERE state='completed' AND query LIKE '%sum(x+1)%' ORDER BY last_update DESC LIMIT 1")
[ "$P" = "1" ]; check "final progress == 1.0" $? "progress=$P"

bg_close 9 s8fifo
finish_scenario
