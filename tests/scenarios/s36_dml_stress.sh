#!/usr/bin/env bash
# s36: DML stress paths.
#  - arm A, big UPDATE cancelled mid-run (SIGINT): slot flips to failed,
#    then is reused by the next query of the same session, no
#    extension-originated errors in the server log
#  - arm B, BEFORE INSERT trigger raising mid-statement: clean ERROR,
#    slot failed, transaction aborted, no residue, no crash
#  - arm C, EXPLAIN ANALYZE INSERT: tracked to completed/1.0 while the
#    EXPLAIN output itself stays intact (no bar/NOTICE pollution)
#  - arm D, auto_explain coexistence (skipped when no auto_explain.so is
#    found): ANALYZE-instrumented DML completes 1.0 and the log carries
#    the plan
source "$(dirname "$BASH_SOURCE")/../common.sh"

q "DROP TABLE IF EXISTS s36_t, s36_r" > /dev/null
q "CREATE TABLE s36_t AS SELECT x, pad FROM big_table" > /dev/null
q "CREATE TABLE s36_r (k int)" > /dev/null
q "ANALYZE s36_t" > /dev/null
check "stress tables ready" $?

# ---- arm A: cancel a big UPDATE ----------------------------------------------
LOG="$WORKDIR/s36.a.log"
bg_open 9 s36afifo "$LOG"
bg_send 9 "BEGIN;"
sendq 9 "UPDATE /* s36a */ s36_t SET pad = 'u' WHERE x <= 4000 AND pg_sleep(0.0003) IS NOT NULL"
wait_until "$(timeout_scale 15)" 'q "SELECT 1 FROM pg_query_progress WHERE state='"'"'running'"'"' AND query LIKE '"'"'%s36a%'"'"' AND pid <> pg_backend_pid()" | grep -q 1'
check "arm A: UPDATE visible as running" $?
PID=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s36a%' AND pid <> pg_backend_pid() LIMIT 1")
[ -n "$PID" ]; check "arm A: got backend pid" $? "pid=$PID"
kill -INT "$PID"
sleep "$(awk -v t="$PGQP_TOLERANCE" 'BEGIN{print 1*t}')"
ST=$(q "SELECT state FROM pg_query_progress WHERE pid = $PID AND pid <> pg_backend_pid()")
[ "$ST" = "failed" ]; check "arm A: slot failed after Ctrl-C mid-UPDATE" $? "state=$ST"
bg_send 9 "ROLLBACK;"
bg_send 9 "SELECT 4242;"
sleep 1
ST2=$(q "SELECT state FROM pg_query_progress WHERE pid = $PID")
TXT=$(q "SELECT left(query, 20) FROM pg_query_progress WHERE pid = $PID")
[ "$ST2" = "completed" ] && [ "$TXT" = "SELECT 4242;" ]
check "arm A: slot reused by next query in same session" $? "state=$ST2 query=$TXT"
bg_close 9 s36afifo

# ---- arm B: trigger RAISE mid-INSERT -----------------------------------------
q "CREATE OR REPLACE FUNCTION s36_raise() RETURNS trigger AS \$\$
     BEGIN
       IF NEW.k = 10000 THEN RAISE EXCEPTION 's36 planned failure at %', NEW.k; END IF;
       RETURN NEW;
     END \$\$ LANGUAGE plpgsql" > /dev/null
q "CREATE TRIGGER s36_br BEFORE INSERT ON s36_r FOR EACH ROW EXECUTE FUNCTION s36_raise()" > /dev/null
LOGB="$WORKDIR/s36.b.log"
bg_open 9 s36bfifo "$LOGB"
sendq 9 "INSERT /* s36b */ INTO s36_r SELECT g FROM generate_series(1, 20000) g"
sleep "$(awk -v t="$PGQP_TOLERANCE" 'BEGIN{print 1*t}')"
grep -q "s36 planned failure" "$LOGB"
check "arm B: trigger raised mid-INSERT" $?
FB=$(q "SELECT state FROM pg_query_progress WHERE query LIKE '%s36b%' ORDER BY last_update DESC LIMIT 1")
[ "$FB" = "failed" ]; check "arm B: slot failed on the aborted INSERT" $? "state=$FB"
RUNNING=$(q "SELECT count(*) FROM pg_query_progress WHERE state = 'running' AND pid <> pg_backend_pid()")
[ "$RUNNING" = "0" ]; check "arm B: no residual running rows" $? "running=$RUNNING"
bg_send 9 "ROLLBACK;"
bg_close 9 s36bfifo
NR=$(q "SELECT count(*) FROM s36_r")
[ "$NR" = "0" ]; check "arm B: aborted transaction left no rows" $? "rows=$NR"
EXTLOG=$(grep -i "pg_query_progress" "$PGDATA/server.log" | grep -ic "error\|warning\|fatal")
[ "$EXTLOG" = "0" ]; check "arm B: no extension errors in server log" $? "matches=$EXTLOG"
SIG=$(grep -c "terminated by signal" "$PGDATA/server.log")
[ "$SIG" = "0" ]; check "arm B: no crash signals in server log" $? "matches=$SIG"

# ---- arm C: EXPLAIN ANALYZE INSERT -------------------------------------------
LOGC="$WORKDIR/s36.c.log"
bg_open 9 s36cfifo "$LOGC"
sendq 9 "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) INSERT /* s36c */ INTO s36_r SELECT g FROM generate_series(1, 5000) g"
wait_until "$(timeout_scale 10)" "grep -q 'Insert on' '$LOGC'"
grep -q "Insert on" "$LOGC"
check "arm C: EXPLAIN output shows the Insert node" $?
grep -qi "notice" "$LOGC"
if [ $? -ne 0 ]; then check "arm C: EXPLAIN output free of bar bytes" 0; else check "arm C: EXPLAIN output free of bar bytes" 1 "$(grep -i notice "$LOGC" | head -1)"; fi
VC=$(q "SELECT state, progress FROM pg_query_progress WHERE query LIKE '%s36c%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
[ "$VC" = "completed|1" ]; check "arm C: EXPLAIN ANALYZE INSERT tracked to completed/1.0" $? "row=$VC"
bg_close 9 s36cfifo
q "DELETE FROM s36_r" > /dev/null

# ---- arm D: auto_explain coexistence ------------------------------------------
AE_SO="${PGQP_AUTO_EXPLAIN_SO:-}"
if [ -z "$AE_SO" ] && [ -n "${PGQP_PKGLIB:-}" ] && [ -f "$PGQP_PKGLIB/auto_explain.so" ]; then
  AE_SO="$PGQP_PKGLIB/auto_explain.so"
fi
if [ -z "$AE_SO" ]; then
  cand="$("$PG_CONFIG_PGQP" --pkglibdir 2>/dev/null)/auto_explain.so"
  [ -f "$cand" ] && AE_SO="$cand"
fi
if [ -z "$AE_SO" ] || [ ! -f "$AE_SO" ]; then
  skip "arm D (auto_explain)" "auto_explain library not found; set PGQP_AUTO_EXPLAIN_SO"
  finish_scenario
  exit 0
fi
echo "  info: auto_explain = $AE_SO"
q "LOAD '$AE_SO'" > /dev/null 2>&1 || true
LOGD="$WORKDIR/s36.d.log"
bg_open 9 s36dfifo "$LOGD"
sendq 9 "LOAD '$AE_SO'"
sendq 9 "SET auto_explain.log_min_duration = 0"
sendq 9 "SET auto_explain.log_analyze = on"
sendq 9 "UPDATE /* s36d */ s36_t SET pad = pad WHERE x <= 2000 AND pg_sleep(0.0003) IS NOT NULL"
wait_until "$(timeout_scale 30)" "q \"SELECT 1 FROM pg_query_progress WHERE query LIKE '%s36d%' AND state='completed'\" | grep -q 1"
VD=$(q "SELECT state, progress FROM pg_query_progress WHERE query LIKE '%s36d%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
[ "$VD" = "completed|1" ]; check "arm D: ANALYZE-instrumented UPDATE completes 1.0" $? "row=$VD"
bg_close 9 s36dfifo
AED=$(grep -c "actual time" "$PGDATA/server.log")
[ "$AED" -ge 1 ]; check "arm D: auto_explain logged the DML plan" $? "matches=$AED"

finish_scenario
