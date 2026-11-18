#!/usr/bin/env bash
# s05: SRFs -- FunctionScan (generate_series) and ProjectSet (ROWS FROM)
# must be tracked as ordinary plan nodes.
source "$(dirname "$BASH_SOURCE")/../common.sh"

LOG="$WORKDIR/s5a.log"
bg_open 9 s5fifo "$LOG"
# 5M keeps the sample window a few seconds
bg_send 9 "SELECT count(*) FROM generate_series(1, 5000000);"

wait_until "$(timeout_scale 15)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'running'"'"' AND pid <> pg_backend_pid() AND query LIKE '"'"'%generate_series%'"'"'" | grep -q 1'
check "FunctionScan query visible running" $?
P1=$(q "SELECT progress FROM pg_query_progress WHERE state='running' AND query LIKE '%generate_series%' AND pid <> pg_backend_pid()")
# generate_series is a materialize-mode SRF: the FunctionScan's first call
# buffers the whole set (a single long node call freezes publishing), so
# 0 <= p < 1 mid-run is acceptable; only p>1 would be a bug.
awk -v p="$P1" 'BEGIN { exit (p >= 0 && p < 1) ? 0 : 1 }'
check "progress within [0,1) mid-run (SRF materialize freeze is expected)" $? "progress=$P1"
wait_until "$(timeout_scale 60)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'completed'"'"' AND query LIKE '"'"'%generate_series%'"'"'" | grep -q 1'
check "FunctionScan query completed" $?
bg_close 9 s5fifo

# ProjectSet coverage: ROWS FROM in FROM clause
LOG2="$WORKDIR/s5b.log"
bg_open 9 s5fifo2 "$LOG2"
bg_send 9 "SELECT count(*) FROM ROWS FROM (generate_series(1, 5000000), generate_series(1, 2)) AS t(a, b);"
wait_until "$(timeout_scale 15)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'running'"'"' AND pid <> pg_backend_pid() AND query LIKE '"'"'%ROWS FROM%'"'"'" | grep -q 1'
check "ProjectSet query visible running" $? "query text matches"
wait_until "$(timeout_scale 60)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'completed'"'"' AND query LIKE '"'"'%ROWS FROM%'"'"'" | grep -q 1'
check "ProjectSet query completed without crash" $?
bg_close 9 s5fifo2
finish_scenario
