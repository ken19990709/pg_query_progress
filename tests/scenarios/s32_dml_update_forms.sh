#!/usr/bin/env bash
# s32: UPDATE progress across three forms.
#
# Stretch mechanism note: a volatile pg_sleep qual costs a floor of about
# 1ms per evaluation (timer slack), so the tables here are deliberately
# small and every form sleeps per candidate row -- matched rows for the
# productive arms (filter first, sleep second: the sleep then fires once
# per row the scan EMITS, which is also what drives the tick clock), and
# every scanned row for the zero-match arm (sleep first: the whole table
# drains inside the scan's single ExecProcNode call).
#
#  - arm A, single-table UPDATE: monotonic with several distinct values,
#    terminal completed/1.0, exactly the matched rows updated
#  - arm B, UPDATE ... FROM (join source): same assertions
#  - arm C, zero-match UPDATE (WHERE rejects every row after the sleep):
#    legal completion -- terminal completed/1.0, every running sample
#    stays at 0.0 (tick starvation: the drained scan never reaches a
#    16-tick checkpoint, so no intermediate frames or view refreshes
#    exist by construction; zero intermediate frames and constant-0.0%
#    frames are both legal)
source "$(dirname "$BASH_SOURCE")/../common.sh"

q "DROP TABLE IF EXISTS s32_a, s32_b, s32_src, s32_z" > /dev/null
q "CREATE TABLE s32_a AS SELECT g AS x, (g * 37) % 997 AS y, repeat('v', 64) AS pad FROM generate_series(1, 4000) g" > /dev/null
q "CREATE TABLE s32_b AS SELECT g AS id, repeat('v', 64) AS pad FROM generate_series(1, 3000) g" > /dev/null
q "CREATE TABLE s32_src AS SELECT g AS id FROM generate_series(1, 3000) g" > /dev/null
q "CREATE TABLE s32_z AS SELECT g AS x, (g * 37) % 997 AS y, repeat('v', 64) AS pad FROM generate_series(1, 1500) g" > /dev/null
q "ANALYZE s32_a; ANALYZE s32_b; ANALYZE s32_src; ANALYZE s32_z" > /dev/null
check "update targets ready" $?

run_form() {                   # run_form <marker> <statement>
  # leaves the terminal readout in TERM_ROW (read before the fifo close)
  local marker="$1" stmt="$2"
  TERM_ROW=""
  bg_open_split 9 "s32$marker"
  sendq 9 "SET max_parallel_workers_per_gather=0"
  sendq 9 "$stmt"
  local pid=""
  wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%$marker%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
    pid=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%$marker%' AND pid <> pg_backend_pid() LIMIT 1")
  [ -n "$pid" ] && poll_progress "$pid" 0.12 "$(timeout_scale 120)" "$WORKDIR/s32.$marker.poll"
  TERM_ROW=$(q "SELECT state, progress FROM pg_query_progress WHERE query LIKE '%$marker%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
  bg_close 9 "s32$marker"
}

# ---- arm A: single-table UPDATE --------------------------------------------
run_form s32a "UPDATE /* s32a */ s32_a SET pad = 'u' WHERE x <= 4000 AND pg_sleep(0.0003) IS NOT NULL"
analyze_polls "$WORKDIR/s32.s32a.poll" armA 3 5
check "arm A (single table): monotonic, >=5 distinct, no collapse" $?
PA="$TERM_ROW"
[ "$PA" = "completed|1" ]; check "arm A: terminal completed/1.0" $? "row=$PA"
UA=$(q "SELECT count(*) FROM s32_a WHERE pad = 'u'")
[ "$UA" = "4000" ]; check "arm A: exactly the matched rows updated" $? "updated=$UA expected=4000"

# ---- arm B: UPDATE ... FROM -------------------------------------------------
run_form s32b "UPDATE /* s32b */ s32_b SET pad = 'updated' FROM s32_src WHERE s32_b.id = s32_src.id AND pg_sleep(0.0003) IS NOT NULL"
analyze_polls "$WORKDIR/s32.s32b.poll" armB 3 5
check "arm B (UPDATE FROM): monotonic, >=5 distinct, no collapse" $?
PB="$TERM_ROW"
[ "$PB" = "completed|1" ]; check "arm B: terminal completed/1.0" $? "row=$PB"
UB=$(q "SELECT count(*) FROM s32_b WHERE pad = 'updated'")
[ "$UB" = "3000" ]; check "arm B: exactly the joined rows updated" $? "updated=$UB expected=3000"

# ---- arm C: zero-match UPDATE (tick starvation, legal completion) -----------
TERM_ROW=""
bg_open_split 9 s32z
sendq 9 "SET pg_query_progress.bar = on"
sendq 9 "UPDATE /* s32z */ s32_z SET pad = pad WHERE pg_sleep(0.0007) IS NOT NULL AND y >= 997"
PZ=""
wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s32z%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
  PZ=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s32z%' AND pid <> pg_backend_pid() LIMIT 1")
[ -n "$PZ" ] && poll_progress "$PZ" 0.1 "$(timeout_scale 120)" "$WORKDIR/s32.s32z.poll"
PZROW=$(q "SELECT state, progress FROM pg_query_progress WHERE query LIKE '%s32z%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
bg_close 9 s32z
[ "$PZROW" = "completed|1" ]; check "arm C: terminal row completed/1.0" $? "row=$PZROW"

python3 - "$WORKDIR/s32.s32z.poll" <<'PYEOF'
import sys
rows = [ln.rstrip("\n").split("\t") for ln in open(sys.argv[1]) if ln.strip()]
run = [r for r in rows if len(r) >= 7 and r[1] == "running"]
term = [r for r in rows if len(r) >= 7 and r[1] != "running"]
ok = bool(term) and all(t[1] == "completed" and float(t[2]) == 1.0 for t in term)
flat = all(float(r[2]) == 0.0 for r in run)
print("  info[armC]: running=%d all-zero=%s term=%s" %
      (len(run), flat, [t[1] + "/" + t[2] for t in term]))
sys.exit(0 if ok and flat else 1)
PYEOF
check "arm C (zero match): running samples stay 0.0, terminal completed/1.0" $?
UZ=$(q "SELECT count(*) FROM s32_z WHERE pad <> repeat('v', 64)")
[ "$UZ" = "0" ]; check "arm C: zero rows matched (nothing updated)" $? "changed=$UZ"

# frame side of arm C: zero or constant-0.0% intermediate frames are both
# legal; whatever frames exist must be monotonic and end with done
ZF=$(bar_count "$WORKDIR/s32z.err")
echo "  info[armC]: frames=$ZF (tick starvation expected: terminal frame only)"
[ "$ZF" -ge 1 ]; check "arm C: terminal frame emitted (elapsed arm of the gate)" $? "frames=$ZF"
MONO=$(bar_monotonic "$WORKDIR/s32z.err")
[ "$MONO" = "0" ]; check "arm C: frame percents monotonic" $? "violations=$MONO"
NONZERO=$(bar_percents "$WORKDIR/s32z.err" | awk '$1+0 > 0 && $1+0 < 100' | wc -l)
[ "$NONZERO" = "0" ]; check "arm C: no intermediate frame above 0%" $? "nonzero_frames=$NONZERO"
bar_lastdone "$WORKDIR/s32z.err"; check "arm C: last frame is '100.0% done'" $?

finish_scenario
