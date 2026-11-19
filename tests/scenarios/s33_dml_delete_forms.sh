#!/usr/bin/env bash
# s33: DELETE progress across two forms.
#
# Same stretch strategy as the UPDATE forms scenario: small tables, one
# ~1ms (floor) pg_sleep per candidate row; the filter precedes the sleep
# so it fires once per row the source emits (arm A) or per joined row
# (arm B).
#
#  - arm A, single-table DELETE: monotonic, terminal completed/1.0,
#    correct surviving count
#  - arm B, DELETE ... USING (join source): same assertions
source "$(dirname "$BASH_SOURCE")/../common.sh"

q "DROP TABLE IF EXISTS s33_t, s33_src" > /dev/null
q "CREATE TABLE s33_t AS SELECT g AS k, repeat('v', 64) AS pad FROM generate_series(1, 4000) g" > /dev/null
# USING source keys overlap only arm A's survivors (arm A deletes k <= 2000)
q "CREATE TABLE s33_src AS SELECT g AS k FROM generate_series(2001, 3500) g" > /dev/null
q "ANALYZE s33_t; ANALYZE s33_src" > /dev/null
check "delete targets ready" $?

run_form() {                   # run_form <marker> <statement>
  # leaves the terminal readout in TERM_ROW (read before the fifo close)
  local marker="$1" stmt="$2"
  TERM_ROW=""
  bg_open 9 "s33$marker" "$WORKDIR/s33.$marker.log"
  sendq 9 "SET max_parallel_workers_per_gather=0"
  sendq 9 "$stmt"
  local pid=""
  wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%$marker%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
    pid=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%$marker%' AND pid <> pg_backend_pid() LIMIT 1")
  [ -n "$pid" ] && poll_progress "$pid" 0.12 "$(timeout_scale 120)" "$WORKDIR/s33.$marker.poll"
  TERM_ROW=$(q "SELECT state, progress FROM pg_query_progress WHERE query LIKE '%$marker%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
  bg_close 9 "s33$marker"
}

# ---- arm A: single-table DELETE --------------------------------------------
run_form s33a "DELETE /* s33a */ FROM s33_t WHERE k <= 2000 AND pg_sleep(0.0003) IS NOT NULL"
analyze_polls "$WORKDIR/s33.s33a.poll" armA 3 5
check "arm A (single table): monotonic, >=5 distinct, no collapse" $?
PA="$TERM_ROW"
[ "$PA" = "completed|1" ]; check "arm A: terminal completed/1.0" $? "row=$PA"
RA=$(q "SELECT count(*) FROM s33_t")
[ "$RA" = "2000" ]; check "arm A: correct surviving count" $? "left=$RA expected=2000"

# ---- arm B: DELETE ... USING -------------------------------------------------
run_form s33b "DELETE /* s33b */ FROM s33_t t USING s33_src s WHERE t.k = s.k AND pg_sleep(0.0003) IS NOT NULL"
analyze_polls "$WORKDIR/s33.s33b.poll" armB 3 5
check "arm B (USING): monotonic, >=5 distinct, no collapse" $?
PB="$TERM_ROW"
[ "$PB" = "completed|1" ]; check "arm B: terminal completed/1.0" $? "row=$PB"
RB=$(q "SELECT count(*) FROM s33_t")
[ "$RB" = "500" ]; check "arm B: correct surviving count" $? "left=$RB expected=500"

finish_scenario
