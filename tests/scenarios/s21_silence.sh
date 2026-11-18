#!/usr/bin/env bash
# s21: unified frame gate -- short/internal SQL silence.
#  - short group: \d, SELECT 1, catalog quick query, pg_sleep(0.3) -> ZERO
#    frames on stderr with bar=on
#  - flowing >=gate group: v2-shaped frame stream (count >= duration/0.5s
#    - 2, monotonic, terminal 100.0% done) with the first frame at
#    query-elapsed in [gate, gate+320ms] (parsed from the frame's own
#    "%.1fs" field -- server-side, wall-clock-immune)
#  - slow SRF group (checkpoint-exhausted): pg_sleep(6) has < 32 node
#    calls, so every 16-tick checkpoint would land before the gate ->
#    exactly ONE terminal frame, no intermediate
#  - explicit gate override: bar_min_query_ms=2000: 1.5s query -> 0 frames;
#    flowing query -> first frame at [2.0s, 2.3s]
source "$(dirname "$BASH_SOURCE")/../common.sh"

GATE=500                      # default: bar_min_query_ms=0 mirrors bar_interval_ms=500

# ---- 0. GUC surface ---------------------------------------------------------
DEF=$(q "SELECT setting FROM pg_settings WHERE name='pg_query_progress.bar_min_query_ms'")
[ "$DEF" = "0" ]; check "bar_min_query_ms default is 0 (mirror sentinel)" $? "setting=$DEF"
CTX=$(q "SELECT context FROM pg_settings WHERE name='pg_query_progress.bar_min_query_ms'")
[ "$CTX" = "user" ]; check "bar_min_query_ms is USERSET" $? "context=$CTX"

# ---- 1. short group: zero frames -------------------------------------------
short_arm() {                   # short_arm <label> <psql args...>
  local label="$1"; shift
  local out="$WORKDIR/s21.$label.out" err="$WORKDIR/s21.$label.err"
  psql -X -q -At "$@" > "$out" 2> "$err"
  local rc=$?
  local frames bytes
  frames=$(bar_count "$err")
  bytes=$(wc -c < "$err")
  [ "$rc" = "0" ] && [ "$frames" = "0" ] && [ "$bytes" = "0" ]
  check "short/$label: query ok and stderr carries ZERO frames/bytes" $? \
        "rc=$rc frames=$frames bytes=$bytes"
}

short_arm dd      -c "SET pg_query_progress.bar=on" -c "\d big_table"
short_arm one     -c "SET pg_query_progress.bar=on" -c "SELECT 1"
short_arm catalog -c "SET pg_query_progress.bar=on" \
                  -c "SELECT count(*) FROM pg_class JOIN pg_attribute ON attrelid = pg_class.oid WHERE relname = 'big_table'"
short_arm sleep03 -c "SET pg_query_progress.bar=on" -c "SELECT pg_sleep(0.3)"

# ---- 2. flowing >=gate group (~6s rate-controlled flow) ---------------------
flow_err="$WORKDIR/s21.flow.err"; : > "$flow_err"
T0=$(date +%s%3N)
psql -X -At -c "SET pg_query_progress.bar=on" \
    -c "SELECT count(*) FROM slow_outer s, LATERAL (SELECT pg_sleep(0.03), s.k + 1 AS v) sub;" \
    > /dev/null 2> "$flow_err"
DUR_MS=$(( $(date +%s%3N) - T0 ))
FRAMES=$(bar_count "$flow_err")
echo "  info: flowing arm duration=${DUR_MS}ms frames=$FRAMES"
MIN_FRAMES=$(( DUR_MS / 500 - 2 ))
[ "$FRAMES" -ge "$MIN_FRAMES" ] && [ "$FRAMES" -ge 2 ]
check "flowing: frame count >= duration/0.5s - 2" $? "frames=$FRAMES min=$MIN_FRAMES"

FFE=$(bar_first_elapsed "$flow_err")
# one guarded re-measure: heavy host load landing between gate and the
# first checkpoint can push the first frame past the window without any
# extension fault; retry once before failing
if [ -z "$FFE" ] || awk -v e="$FFE" 'BEGIN{exit (e<0.5||e>0.8)?0:1}'; then
  flow_err="$WORKDIR/s21.flow2.err"; : > "$flow_err"
  psql -X -At -c "SET pg_query_progress.bar=on" \
      -c "SELECT count(*) FROM slow_outer s, LATERAL (SELECT pg_sleep(0.03), s.k + 1 AS v) sub;" \
      > /dev/null 2> "$flow_err"
  FRAMES=$(bar_count "$flow_err")
  FFE=$(bar_first_elapsed "$flow_err")
fi
awk -v e="$FFE" 'BEGIN{exit (e>=0.5&&e<=0.8)?0:1}'
check "flowing: first frame query-elapsed in [gate, gate+320ms] (=0.5-0.8s)" $? "elapsed=${FFE}s"
MONO=$(bar_monotonic "$flow_err")
[ "$MONO" = "0" ]; check "flowing: percent sequence monotonic" $? "violations=$MONO"
bar_lastdone "$flow_err"; check "flowing: last frame is '100.0% done'" $?

# ---- 3. slow SRF group: exactly one terminal frame -------------------------
srf_err="$WORKDIR/s21.srf.err"; : > "$srf_err"
psql -X -At -c "SET pg_query_progress.bar=on" -c "SELECT pg_sleep(6)" \
    > /dev/null 2> "$srf_err"
SRF_FRAMES=$(bar_count "$srf_err")
[ "$SRF_FRAMES" = "1" ]
check "slow SRF (pg_sleep(6), <32 node calls, >=gate): EXACTLY one frame" $? "frames=$SRF_FRAMES"
bar_lastdone "$srf_err"
check "slow SRF: the single frame is the '100.0% done' terminal (elapsed>=gate arm)" $?

# ---- 4. explicit gate override (bar_min_query_ms=2000) ---------------------
g_err="$WORKDIR/s21.gate2k.short.err"; : > "$g_err"
psql -X -At -c "SET pg_query_progress.bar=on" \
               -c "SET pg_query_progress.bar_min_query_ms=2000" \
               -c "SELECT pg_sleep(1.5)" > /dev/null 2> "$g_err"
G_FRAMES=$(bar_count "$g_err")
[ "$G_FRAMES" = "0" ]
check "explicit gate 2000ms: 1.5s checkpoint-exhausted query -> 0 frames" $? "frames=$G_FRAMES"

Q4="SELECT sum(c) FROM ("
for i in 1 2 3 4; do Q4+=" SELECT count(*), sum(x + 1) AS c FROM big_table"; [ "$i" = 4 ] || Q4+=" UNION ALL"; done
Q4+=") t"
g2_err="$WORKDIR/s21.gate2k.flow.err"; : > "$g2_err"
psql -X -At -c "SET pg_query_progress.bar=on" \
               -c "SET pg_query_progress.bar_min_query_ms=2000" \
               -c "SET max_parallel_workers_per_gather=0" \
               -c "$Q4" > /dev/null 2> "$g2_err"
FFE2=$(bar_first_elapsed "$g2_err")
if [ -z "$FFE2" ] || awk -v e="$FFE2" 'BEGIN{exit (e<2.0||e>2.3)?0:1}'; then
  g2_err="$WORKDIR/s21.gate2k.flow2.err"; : > "$g2_err"
  psql -X -At -c "SET pg_query_progress.bar=on" \
                 -c "SET pg_query_progress.bar_min_query_ms=2000" \
                 -c "SET max_parallel_workers_per_gather=0" \
                 -c "$Q4" > /dev/null 2> "$g2_err"
  FFE2=$(bar_first_elapsed "$g2_err")
fi
awk -v e="$FFE2" 'BEGIN{exit (e>=2.0&&e<=2.3)?0:1}'
check "explicit gate 2000ms: flowing first frame in [2.0s, 2.3s]" $? "elapsed=${FFE2}s"
G2_FRAMES=$(bar_count "$g2_err")
[ "$G2_FRAMES" -ge 3 ]; check "explicit gate 2000ms: flowing arm emits intermediate frames" $? "frames=$G2_FRAMES"

finish_scenario
