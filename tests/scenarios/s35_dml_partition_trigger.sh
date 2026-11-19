#!/usr/bin/env bash
# s35: partitioned targets and BEFORE row triggers.
#  - arm A, INSERT..SELECT routed into range partitions: monotonic,
#    terminal completed/1.0, correct per-partition counts
#  - arm B, BEFORE INSERT trigger skipping half the rows (parity):
#    progress still advances to 1.0 (frac follows CONSUMED source rows,
#    skipped rows were already examined), final count = odd keys only
#  - arm C, BEFORE INSERT trigger rewriting rows: values land rewritten
#  - arm D, BEFORE UPDATE trigger rewriting across partitions (filter on
#    a non-partition key, so no pruning): monotonic, terminal 1.0
#  - arm E, DELETE across partitions: terminal 1.0, correct counts
source "$(dirname "$BASH_SOURCE")/../common.sh"

# Row count sized for the trigger arms' sampling-density assertions to
# hold on BOTH -O0 debug and -O2 release kernels: per-row trigger cost
# differs ~3-4x between the two, and at the former 200k-row default the
# skip/rewrite arms completed within ~2 publishes on -O2 (distinct < 3).
# Bigger N only stretches the arms; every assertion is behavioral.
N=$(awk -v s="${PGQP_SCALE:-0.1}" 'BEGIN{n=int(600000*s/0.1); if(n<60000)n=60000; if(n>800000)n=800000; print n}')
Q=$(( N / 4 ))

q "DROP TABLE IF EXISTS s35_p CASCADE" > /dev/null
q "CREATE TABLE s35_p (k int, v int, pad text) PARTITION BY RANGE (k)" > /dev/null
q "CREATE TABLE s35_p0 PARTITION OF s35_p FOR VALUES FROM (0) TO ($Q)" > /dev/null
q "CREATE TABLE s35_p1 PARTITION OF s35_p FOR VALUES FROM ($Q) TO ($(( 2 * Q )))" > /dev/null
q "CREATE TABLE s35_p2 PARTITION OF s35_p FOR VALUES FROM ($(( 2 * Q ))) TO ($(( 3 * Q )))" > /dev/null
q "CREATE TABLE s35_p3 PARTITION OF s35_p FOR VALUES FROM ($(( 3 * Q ))) TO (MAXVALUE)" > /dev/null
q "CREATE OR REPLACE FUNCTION s35_trig() RETURNS trigger AS \$\$
     BEGIN
       IF TG_OP = 'INSERT' THEN
         IF current_setting('s35.mode', true) = 'skip' AND NEW.k % 2 = 0 THEN
           RETURN NULL;
         END IF;
         IF current_setting('s35.mode', true) = 'rewrite' THEN
           NEW.v := NEW.v + 1000000;
         END IF;
         RETURN NEW;
       ELSIF TG_OP = 'UPDATE' THEN
         IF current_setting('s35.mode', true) = 'rewrite' THEN
           NEW.v := NEW.v + 2000000;
         END IF;
         RETURN NEW;
       END IF;
       RETURN NULL;
     END \$\$ LANGUAGE plpgsql" > /dev/null
q "CREATE TRIGGER s35_br BEFORE INSERT OR UPDATE ON s35_p FOR EACH ROW EXECUTE FUNCTION s35_trig()" > /dev/null
check "partitioned target + trigger ready (N=$N quarter=$Q)" $?

run_arm() {                    # run_arm <marker> <statement>
  # leaves the terminal readout in TERM_ROW (read before the fifo close)
  local marker="$1" stmt="$2"
  TERM_ROW=""
  bg_open 9 "s35$marker" "$WORKDIR/s35.$marker.log"
  sendq 9 "SET max_parallel_workers_per_gather=0"
  sendq 9 "$stmt"
  local pid=""
  wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%$marker%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
    pid=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%$marker%' AND pid <> pg_backend_pid() LIMIT 1")
  [ -n "$pid" ] && poll_progress "$pid" 0.12 "$(timeout_scale 240)" "$WORKDIR/s35.$marker.poll"
  TERM_ROW=$(q "SELECT state, progress FROM pg_query_progress WHERE query LIKE '%$marker%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
  bg_close 9 "s35$marker"
}

term_check() {                 # term_check <label> <row>
  [ "$2" = "completed|1" ]; check "$1: terminal completed/1.0" $? "row=$2"
}

# ---- arm A: partition-routed INSERT ----------------------------------------
bg_open 9 s35a "$WORKDIR/s35.a.log"
sendq 9 "SET max_parallel_workers_per_gather=0"
sendq 9 "SET s35.mode = 'plain'"
sendq 9 "INSERT /* s35a */ INTO s35_p SELECT g, g, repeat('v', 16) FROM generate_series(1, $N) g"
PID=""
wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s35a%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
  PID=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s35a%' AND pid <> pg_backend_pid() LIMIT 1")
[ -n "$PID" ]; check "arm A: leader row visible while running" $? "pid=${PID:-none}"
[ -n "$PID" ] && poll_progress "$PID" 0.12 "$(timeout_scale 240)" "$WORKDIR/s35.a.poll"
VA=$(q "SELECT state, progress FROM pg_query_progress WHERE query LIKE '%s35a%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
bg_close 9 s35a
analyze_polls "$WORKDIR/s35.a.poll" armA 2 3
check "arm A (routed INSERT): monotonic, no collapse" $?
term_check "arm A" "$VA"
PA=$(q "SELECT count(*) FROM s35_p")
[ "$PA" = "$N" ]; check "arm A: all rows landed across partitions" $? "rows=$PA expected=$N"
P0=$(q "SELECT count(*) FROM s35_p0"); P1=$(q "SELECT count(*) FROM s35_p1")
P2=$(q "SELECT count(*) FROM s35_p2"); P3=$(q "SELECT count(*) FROM s35_p3")
[ "$P0" = "$(( Q - 1 ))" ] && [ "$P1" = "$Q" ] && [ "$P2" = "$Q" ] && [ "$P3" = "$(( N - 3 * Q + 1 ))" ]
check "arm A: per-partition routing" $? "p0=$P0 p1=$P1 p2=$P2 p3=$P3"

# ---- arm B: BEFORE trigger skipping rows ------------------------------------
q "TRUNCATE s35_p" > /dev/null
run_arm s35b "SET s35.mode = 'skip'; INSERT /* s35b */ INTO s35_p SELECT g, g, repeat('v', 16) FROM generate_series(1, $N) g"
RESB="$TERM_ROW"
analyze_polls "$WORKDIR/s35.s35b.poll" armB 2 3
check "arm B (skip): monotonic, no collapse" $?
term_check "arm B" "$RESB"
ODD=$(awk -v n="$N" 'BEGIN{print int((n+1)/2)}')
PB=$(q "SELECT count(*) FROM s35_p")
[ "$PB" = "$ODD" ]; check "arm B: exactly the non-skipped (odd) rows landed" $? "rows=$PB odd=$ODD"

# ---- arm C: BEFORE trigger rewriting rows ------------------------------------
q "TRUNCATE s35_p" > /dev/null
run_arm s35c "SET s35.mode = 'rewrite'; INSERT /* s35c */ INTO s35_p SELECT g, g, repeat('v', 16) FROM generate_series(1, $N) g"
RESC="$TERM_ROW"
analyze_polls "$WORKDIR/s35.s35c.poll" armC 2 3
check "arm C (rewrite INSERT): monotonic, no collapse" $?
term_check "arm C" "$RESC"
RW=$(q "SELECT count(*) FROM s35_p WHERE v BETWEEN 1000001 AND 1000000 + $N")
[ "$RW" = "$N" ]; check "arm C: all rows landed rewritten (v + 1000000)" $? "rewritten=$RW expected=$N"

# ---- arm D: BEFORE UPDATE trigger rewriting (no partition pruning) ----------
# no sleep qual here: it would fire once per SCANNED row; the per-row
# trigger on half the table provides the runtime instead
UPDABLE=$(q "SELECT count(*) FROM s35_p WHERE v % 2 = 0")
run_arm s35d "SET s35.mode = 'rewrite'; UPDATE /* s35d */ s35_p SET pad = 'u' WHERE v % 2 = 0"
RESD="$TERM_ROW"
analyze_polls "$WORKDIR/s35.s35d.poll" armD 2 3
check "arm D (rewrite UPDATE): monotonic, no collapse" $?
term_check "arm D" "$RESD"
UD=$(q "SELECT count(*) FROM s35_p WHERE v >= 2000000")
[ "$UD" = "$UPDABLE" ]; check "arm D: matched rows updated with rewritten value" $? "rewritten=$UD expected=$UPDABLE"

# ---- arm E: DELETE across partitions -----------------------------------------
DELETABLE=$(q "SELECT count(*) FROM s35_p WHERE v % 5 = 0")
run_arm s35e "DELETE /* s35e */ FROM s35_p WHERE v % 5 = 0"
RESE="$TERM_ROW"
term_check "arm E" "$RESE"
REM=$(q "SELECT count(*) FROM s35_p")
[ "$REM" = "$(( N - DELETABLE ))" ]
check "arm E: deleted across partitions, survivors correct" $? "left=$REM expected=$(( N - DELETABLE ))"

finish_scenario
