#!/usr/bin/env bash
# s01: cancellation.  Session 1 runs a rate-controlled query; the backend
# gets SIGINT mid-run; the slot must flip to failed, then be reused by the
# next query of the same session, with no extension-originated
# WARNING/ERROR in the server log.
source "$(dirname "$BASH_SOURCE")/../common.sh"

LOG="$WORKDIR/s1.log"
bg_open 9 s1fifo "$LOG"
bg_send 9 "BEGIN;"
# correlated LATERAL (references b.x) so pg_sleep runs once per row
bg_send 9 "SELECT count(*) FROM (SELECT x FROM big_table LIMIT 3000) b, LATERAL (SELECT pg_sleep(0.003), b.x AS v) s;"

wait_until "$(timeout_scale 15)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'running'"'"' AND pid <> pg_backend_pid()" | grep -q 1'
check "query visible as running while executing" $?

PID=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND pid <> pg_backend_pid() LIMIT 1")
[ -n "$PID" ]; check "got backend pid" $? "pid=$PID"

kill -INT "$PID"
sleep "$(awk -v t="$PGQP_TOLERANCE" 'BEGIN{print 1*t}')"

ST=$(q "SELECT state FROM pg_query_progress WHERE pid = $PID AND pid <> pg_backend_pid()")
[ "$ST" = "failed" ]; check "slot state is failed after Ctrl-C" $? "state=$ST"

bg_send 9 "ROLLBACK;"          # the cancel left the tx aborted
bg_send 9 "SELECT 4242;"
sleep 1
ST2=$(q "SELECT state FROM pg_query_progress WHERE pid = $PID")
TXT=$(q "SELECT left(query, 20) FROM pg_query_progress WHERE pid = $PID")
[ "$ST2" = "completed" ] && [ "$TXT" = "SELECT 4242;" ]
check "slot reused by next query in same session" $? "state=$ST2 query=$TXT"

EXTLOG=$(grep -i "pg_query_progress" "$PGDATA/server.log" | grep -ic "error\|warning\|fatal")
[ "$EXTLOG" = "0" ]; check "no extension errors in server log" $? "matches=$EXTLOG"

bg_send 9 "COMMIT;"
bg_close 9 s1fifo
finish_scenario
