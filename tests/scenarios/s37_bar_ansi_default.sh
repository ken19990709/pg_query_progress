#!/usr/bin/env bash
# s37: bar_ansi default is on (single-line redraw).
#  - default arm (bar=on only, bar_ansi untouched): the first frame
#    carries the erase-only prefix ESC[2K CR and NO cursor-up byte;
#    every later frame carries ESC[1A ESC[2K CR; percents monotonic;
#    terminal done frame
#  - off arm (bar_ansi=off): zero escape bytes anywhere, same frame
#    order of magnitude, terminal done frame
source "$(dirname "$BASH_SOURCE")/../common.sh"

psql -X -q -v ON_ERROR_STOP=1 -v scale="${PGQP_SCALE:-0.1}" -f "$TESTS_DIR/setup.sql" > /dev/null 2>&1
check "workload tables ready" $?

REPEATS="${PGQP_S37_REPEATS:-$(awk -v s="${PGQP_SCALE:-0.1}" 'BEGIN{r=24/(8*s); printf "%d", (r<2)?2:int(r+0.5)}')}"
Q="SELECT sum(c) FROM ("
for i in $(seq 1 "$REPEATS"); do Q+=" SELECT count(*), sum(x + 1) AS c FROM big_table"; [ "$i" = "$REPEATS" ] || Q+=" UNION ALL"; done
Q+=") t"

run_bar() {                    # run_bar <outfile> [pgoptions-env]
  local err="$1"
  : > "$err"
  PGOPTIONS="${2:-}" psql -X -At \
               -c "SET pg_query_progress.bar = on" \
               -c "SET max_parallel_workers_per_gather = 0" \
               -c "$Q" > /dev/null 2> "$err"
}

# ---- default arm -------------------------------------------------------------
ERRD="$WORKDIR/s37.default.err"
run_bar "$ERRD"
FD=$(bar_count "$ERRD")
echo "  info: default arm frames=$FD"
[ "$FD" -ge 2 ]; check "default arm: frames emitted" $? "frames=$FD"

python3 - "$ERRD" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
lines = [ln for ln in data.split(b"\n") if b"NOTICE" in ln]
first = lines[0] if lines else b""
later = lines[1:] if lines else []
ok_first = b"\x1b[2K\r" in first and b"\x1b[1A" not in first
ok_later = (not later) or any(b"\x1b[1A\x1b[2K\r" in ln for ln in later)
print("  info: first-frame prefix ok=%s later-redraw ok=%s (frames=%d)" %
      (ok_first, ok_later, len(lines)))
sys.exit(0 if ok_first and ok_later else 1)
PYEOF
check "default arm: first frame = ESC[2K CR only; later frames = ESC[1A ESC[2K CR" $?

MONOD=$(bar_monotonic "$ERRD")
[ "$MONOD" = "0" ]; check "default arm: percents monotonic" $? "violations=$MONOD"
bar_lastdone "$ERRD"; check "default arm: last frame is '100.0% done'" $?

# ---- off arm ------------------------------------------------------------------
ERRO="$WORKDIR/s37.off.err"
run_bar "$ERRO" "-c pg_query_progress.bar_ansi=off"
FO=$(bar_count "$ERRO")
ESC=$(python3 -c 'import sys
data = open(sys.argv[1], "rb").read()
print(data.count(b"\x1b"))' "$ERRO")
echo "  info: off arm frames=$FO esc_bytes=$ESC"
[ "$FO" -ge 2 ]; check "off arm: frames still emitted (append mode)" $? "frames=$FO"
[ "$ESC" = "0" ]; check "off arm: zero escape bytes" $? "esc_bytes=$ESC"
MONOO=$(bar_monotonic "$ERRO")
[ "$MONOO" = "0" ]; check "off arm: percents monotonic" $? "violations=$MONOO"
bar_lastdone "$ERRO"; check "off arm: last frame is '100.0% done'" $?

# frame counts of the two arms are the same order of magnitude
SAME=$(awk -v a="$FD" -v b="$FO" 'BEGIN{print (a==0||b==0)?0:((a>b?a:b)<=3*(a<b?a:b))?1:0}')
[ "$SAME" = "1" ]; check "frame counts same order of magnitude" $? "default=$FD off=$FO"

finish_scenario
