#!/usr/bin/env bash
# s06: LIMIT -- tiny and large limits must not crash and must end at 1.0
# (forced completion despite unsaturated children).  Uses a persistent
# session: the queries are fast and their terminal rows vanish when the
# session exits (the process-exit fallback clears the slot).
source "$(dirname "$BASH_SOURCE")/../common.sh"

LOG="$WORKDIR/s6.log"
bg_open 9 s6fifo "$LOG"

for LIM in 100 5000000; do
  bg_send 9 "SELECT * FROM big_table LIMIT $LIM;"
  wait_until "$(timeout_scale 40)" "q \"SELECT 1 FROM pg_query_progress WHERE query LIKE '%LIMIT $LIM%' AND state='completed' AND pid <> pg_backend_pid()\" | grep -q 1"
  check "LIMIT $LIM executed, no crash" $? ""
  ROW=$(q "SELECT round(progress::numeric, 6) FROM pg_query_progress WHERE query LIKE '%big_table LIMIT $LIM%' AND state='completed' AND pid <> pg_backend_pid() ORDER BY last_update DESC LIMIT 1")
  [ "$ROW" = "1.000000" ]; check "LIMIT $LIM final progress == 1.0" $? "progress=$ROW"
  sleep 0.3
done

bg_close 9 s6fifo
finish_scenario
