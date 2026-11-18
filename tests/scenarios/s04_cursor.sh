#!/usr/bin/env bash
# s04: cursor FETCH loop, including the mid-way CLOSE variant (state must
# be 'terminated' with progress < 1, not 100%) and the cursor/plain query
# interleave (one tracked portal per session).
source "$(dirname "$BASH_SOURCE")/../common.sh"

LOG="$WORKDIR/s4.log"
bg_open 9 s4fifo "$LOG"

# explicit transaction: without it each statement autocommits and the
# non-hold portal is dropped before the first FETCH
bg_send 9 "BEGIN;"
bg_send 9 "DECLARE c CURSOR FOR SELECT x, repeat('p', 64) FROM big_table;"
bg_send 9 "FETCH 1000 FROM c;"

wait_until "$(timeout_scale 15)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'running'"'"' AND pid <> pg_backend_pid() AND query LIKE '"'"'%DECLARE%'"'"'" | grep -q 1'
check "cursor query tracked as running during FETCH" $?

MONO=$(q "
  WITH s AS (
    SELECT progress, lag(progress) OVER (ORDER BY last_update) AS prev
    FROM pg_query_progress
    WHERE query LIKE '%DECLARE%' AND state='running'
      AND pid <> pg_backend_pid())
  SELECT count(*) FROM s WHERE prev IS NOT NULL AND progress < prev - 1e-9")
[ "$MONO" = "0" ]; check "cursor progress monotonic" $? "violations=$MONO"

bg_send 9 "FETCH 1000 FROM c;"
sleep 1
# mid-way CLOSE without draining: expect terminated, progress < 1
bg_send 9 "CLOSE c;"
wait_until "$(timeout_scale 10)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'terminated'"'"' AND query LIKE '"'"'%DECLARE%'"'"' AND pid <> pg_backend_pid()" | grep -q 1'
check "mid-way CLOSE => state terminated" $?

P=$(q "SELECT progress FROM pg_query_progress WHERE state='terminated' AND query LIKE '%DECLARE%' AND pid <> pg_backend_pid()")
awk -v p="$P" 'BEGIN { exit (p < 1.0 && p >= 0.0) ? 0 : 1 }'
check "terminated progress kept below 1.0 (no false 100%)" $? "progress=$P"

# ---- cursor / plain query interleave --------------------------------------
# one portal per session is tracked: the plain query's ExecutorStart stops
# tracking the still-open cursor (TERMINATED, not FAILED) and claims the slot.
bg_send 9 "DECLARE c2 CURSOR FOR SELECT x, repeat('q', 32) FROM big_table;"
bg_send 9 "FETCH 20000 FROM c2;"
wait_until "$(timeout_scale 10)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'running'"'"' AND query LIKE '"'"'%c2%'"'"' AND pid <> pg_backend_pid()" | grep -q 1'
check "cursor c2 tracked running before interleave" $?

bg_send 9 "SELECT 43;"
wait_until "$(timeout_scale 10)" 'q "SELECT 1 FROM pg_query_progress WHERE query = '"'"'SELECT 43;'"'"' AND state='"'"'completed'"'"' AND pid <> pg_backend_pid()" | grep -q 1'
check "interleaved plain query tracked to completed" $?

FAILED=$(q "SELECT count(*) FROM pg_query_progress WHERE pid <> pg_backend_pid() AND state='failed'")
[ "$FAILED" = "0" ]; check "interleave recorded no failed row for the live cursor" $? "failed=$FAILED"

bg_send 9 "FETCH 20000 FROM c2;"       # cursor must remain usable
sleep 0.5
ERRS=$(grep -c "ERROR" "$LOG")
[ "$ERRS" = "0" ]; check "cursor still fetchable after interleave" $? "errors=$ERRS"
bg_send 9 "CLOSE c2;"

bg_send 9 "COMMIT;"
bg_close 9 s4fifo
finish_scenario
