#!/usr/bin/env bash
# s03: prepared statement executed 3 times; each execution is an
# independent running->completed cycle for the same pid.
source "$(dirname "$BASH_SOURCE")/../common.sh"

LOG="$WORKDIR/s3.log"
bg_open 9 s3fifo "$LOG"
bg_send 9 "PREPARE p AS SELECT count(*) FROM big_table WHERE x < \$1;"

# NOTE: a prepared-statement slot shows the PREPARE text as query
# (queryDesc->sourceText comes from the cached statement's portal), not
# the EXECUTE text; match on 'PREPARE p'.
for i in 1 2 3; do
  bg_send 9 "EXECUTE p (100);"
  wait_until "$(timeout_scale 30)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'completed'"'"' AND query LIKE '"'"'%PREPARE p AS%'"'"'" | grep -q 1'
  check "execution #$i reached completed" $?
  sleep 0.3
done

# progress must be exactly 1.0 on the last completed row
P=$(q "SELECT progress FROM pg_query_progress WHERE state='completed' AND query LIKE '%PREPARE p AS%' ORDER BY last_update DESC LIMIT 1")
[ "$P" = "1" ]; check "completed progress == 1.0" $? "progress=$P"

bg_send 9 "DEALLOCATE p;"
bg_close 9 s3fifo
finish_scenario
