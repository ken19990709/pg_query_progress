#!/usr/bin/env bash
# s27 (stable branches only): parallel_leader_participation=off arm.
# On PostgreSQL 18 and earlier the leader's local participation is a
# PGC_USERSET GUC; setting it off makes the leader NOT scan the parallel
# plan locally (Gather and Gather Merge alike), so:
#   - the progress denominator must use D-hat = W (not W + max(0,1-0.3W));
#     using the on-formula would understate mid-run progress by up to a
#     factor W/(W + max(0,1-0.3W)) (17% at W=2 -- the value used here);
#   - every tuple counted in the view mid-run comes from a WORKER: worker
#     counters must be merged into the leader's view for progress to move
#     at all (this is the strongest end-to-end check of the worker-side
#     leader identity on any major).
# Assertions per arm (Gather form and Gather Merge form):
#   - plan shape (Gather/Gather Merge, Workers Planned: 2)
#   - mid-run: monotonic, >= 5 distinct values, tuples strictly growing
#   - terminal completed/1.0
#   - max mid-run progress >= 0.60
#   - discriminator: a sample in the last quarter of the run must show
#     progress >= 0.70 (the on-formula misread tops out around 0.83 x true
#     progress, i.e. below 0.70 there); catches a D-hat regression
source "$(dirname "$BASH_SOURCE")/../common.sh"

# ---- 0. GUC availability (main branch / PG >= 19: absent -> skip) -----------
HASGUC=$(q "SELECT count(*) FROM pg_settings WHERE name = 'parallel_leader_participation'")
if [ "$HASGUC" != "1" ]; then
  skip "parallel_leader_participation GUC not present on this server"
  finish_scenario
  exit 0
fi
DEF=$(q "SELECT setting FROM pg_settings WHERE name='parallel_leader_participation'")
[ "$DEF" = "on" ]; check "GUC present, default on" $? "setting=$DEF"

SSCALE="${PGQP_SCALE:-0.1}"
psql -X -q -v ON_ERROR_STOP=1 -v sscale="$SSCALE" -f "$TESTS_DIR/setup_star.sql" > /dev/null 2>&1
check "star schema ready (sscale=$SSCALE)" $?
# pin two planned workers regardless of table size / chosen access path
q "ALTER TABLE dim_customers SET (parallel_workers = 2)" > /dev/null
q "ANALYZE dim_customers" > /dev/null

run_arm() {                    # run_arm <label> <shape-grep> <query>
  local label="$1" shape="$2" query="$3"
  local sets="SET parallel_leader_participation=off; SET max_parallel_workers_per_gather=2"

  local ex
  ex=$(psql -X -q -At -c "$sets" -c "EXPLAIN (COSTS OFF) $query" 2>&1)
  echo "$ex" > "$WORKDIR/s27.$label.explain.txt"
  echo "$ex" | grep -q "$shape"
  check "$label plan contains $shape" $?
  echo "$ex" | grep -q "Workers Planned: 2"
  check "$label plans 2 workers" $?

  local log="$WORKDIR/s27.$label.log" pollf="$WORKDIR/s27.$label.poll"
  bg_open 9 "s27$label" "$log"
  sendq 9 "$sets"
  sendq 9 "$query"
  local pid=""
  wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%${label}%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
    pid=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%${label}%' AND pid <> pg_backend_pid() LIMIT 1")
  [ -n "$pid" ]; check "$label leader row visible" $? "pid=${pid:-none}"
  : > "$pollf"
  [ -n "$pid" ] && poll_progress "$pid" 0.12 "$(timeout_scale 300)" "$pollf"
  bg_close 9 "s27$label"

  python3 - "$pollf" "$label" <<'PYEOF'
import sys
pollf, label = sys.argv[1], sys.argv[2]
rows = [ln.rstrip("\n").split("\t") for ln in open(pollf) if ln.strip()]
run = [(int(r[0]), float(r[2]), float(r[4])) for r in rows if len(r) >= 7 and r[1] == "running"]
term = [r for r in rows if len(r) >= 7 and r[1] != "running"]
prog = [p for _, p, _ in run]
def dec(v): return sum(1 for i in range(1, len(v)) if v[i] < v[i-1] - 1e-9)
def incs(v): return sum(1 for i in range(1, len(v)) if v[i] > v[i-1] + 1e-9)
print("  info[%s]: running=%d distinct=%d max=%.3f dec=%d inc(tp)=%d term=%s" %
      (label, len(run), len(set(prog)), max(prog) if prog else -1, dec(prog),
       incs([t for _, _, t in run]), [t[1] + "/" + t[2] for t in term]))
if not run or not term or term[-1][1] != "completed" or float(term[-1][2]) != 1.0:
    sys.exit(1)
if dec(prog) > 0 or len(set(prog)) < 5 or incs([t for _, _, t in run]) < 3:
    sys.exit(1)
if max(prog) < 0.60:
    sys.exit(1)
# D-hat discriminator: last-quarter sample must read >= 0.70
t0, t1 = run[0][0], run[-1][0]
lastq = [p for t, p, _ in run if t1 > t0 and t >= t0 + 0.75 * (t1 - t0)]
if not lastq or max(lastq) < 0.70:
    print("  info[%s]: last-quarter max=%.3f (< 0.70)" % (label, max(lastq) if lastq else -1))
    sys.exit(1)
sys.exit(0)
PYEOF
  check "$label: monotonic, >=5 distinct, terminal 1.0, max>=0.60, last-quarter>=0.70" $?

  # worker-merge proof: with participation off the leader scans nothing
  # locally inside the parallel region, so ANY mid-run tuples growth in
  # the view is worker data merged through the worker table.
  python3 - "$pollf" "$label" <<'PYEOF'
import sys
pollf, label = sys.argv[1], sys.argv[2]
rows = [ln.rstrip("\n").split("\t") for ln in open(pollf) if ln.strip()]
tp = [float(r[4]) for r in rows if len(r) >= 7 and r[1] == "running"]
grow = sum(1 for i in range(1, len(tp)) if tp[i] > tp[i-1] + 1e-9)
print("  info[%s]: tuples growth steps=%d (leader contributes none with participation off)" % (label, grow))
sys.exit(0 if grow >= 3 else 1)
PYEOF
  check "$label: worker counters merged (tuples grow with leader idle)" $?
}

# Gather form: plain count over the star cross join
run_arm s27g "Gather" \
  "SELECT /* s27g */ count(*) FROM dim_dates d, dim_customers c, dim_stores WHERE d.cal_date = c.reg_date"

# Gather Merge form: ORDER BY forces a parallel sort under Gather Merge
run_arm s27gm "Gather Merge" \
  "SELECT /* s27gm */ count(x) FROM (SELECT c.customer_id AS x FROM dim_customers c, dim_dates d WHERE d.cal_date = c.reg_date ORDER BY c.customer_id) s"

finish_scenario
