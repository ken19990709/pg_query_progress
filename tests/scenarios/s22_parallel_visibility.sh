#!/usr/bin/env bash
# s22: parallel-query progress is REAL (visibility core).
#  - star schema cross-join count (setup_star.sql) with 2 workers:
#    view polling must show progress monotonic non-decreasing, >= 5
#    distinct values, terminal completed/1.0, parallel=t, and
#    completed_cost/tuples_processed without mid-run collapse;
#  - worker-merge proof: with the default parallel_leader_participation=on
#    the leader locally scans only ~1/2.4 of the work for W=2; if worker
#    counters were NOT merged into the leader's view, tuples_processed
#    could only grow at the leader's lone rate.  Assert that some poll
#    interval observes a rate clearly above that lone-share rate (this is
#    the assertion that guards the pre-17 leader-identity compatibility
#    path, where workers find their leader through the lock group);
#  - multi-Gather UNION ALL shape (one Gather per branch): zero collapse
#    of completed_cost/tuples_processed (each branch's worker counters
#    must be keyed by its own subtree root).
source "$(dirname "$BASH_SOURCE")/../common.sh"

SSCALE="${PGQP_SCALE:-0.1}"
psql -X -q -v ON_ERROR_STOP=1 -v sscale="$SSCALE" -f "$TESTS_DIR/setup_star.sql" > /dev/null 2>&1
check "star schema ready (sscale=$SSCALE)" $?
ND=$(q "SELECT count(*) FROM dim_dates")
NC=$(q "SELECT count(*) FROM dim_customers")
[ "$ND" = "3650" ] && [ "$NC" -gt 0 ]
check "star schema sanity (dates=3650 customers=$NC)" $? "dates=$ND customers=$NC"

# ---- arm A: single-Gather count query --------------------------------------
QA="SELECT /* s22main */ count(*) FROM dim_dates d, dim_customers c, dim_stores WHERE d.cal_date = c.reg_date"

EX=$(q "SET max_parallel_workers_per_gather=2; EXPLAIN (COSTS OFF) $QA")
echo "$EX" | grep -q "Gather"
check "arm A plan contains Gather" $?
echo "$EX" | grep -q "Workers Planned: 2"
check "arm A plans 2 workers" $?

LOG="$WORKDIR/s22.a.log"
bg_open_split 9 s22fifo
sendq 9 "SET max_parallel_workers_per_gather=2"
sendq 9 "SET pg_query_progress.bar=on"
sendq 9 "$QA"

PID=""
wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s22main%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
  PID=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s22main%' AND pid <> pg_backend_pid() LIMIT 1")
[ -n "$PID" ]; check "arm A leader row visible while running" $? "pid=${PID:-none}"

POLLF="$WORKDIR/s22.a.poll"
if [ -n "$PID" ]; then
  poll_progress "$PID" 0.12 "$(timeout_scale 240)" "$POLLF"
fi
bg_close 9 s22fifo

analyze_polls "$POLLF" armA 3 5
check "arm A: monotonic, >=5 distinct, cc/tp strictly growing, no collapse" $?

python3 - "$POLLF" <<'PYEOF'
import sys
rows = [ln.rstrip("\n").split("\t") for ln in open(sys.argv[1]) if ln.strip()]
run = [r for r in rows if len(r) >= 8 and r[1] == "running"]
term = [r for r in rows if len(r) >= 8 and r[1] != "running"]
ok = bool(term) and all(t[1] == "completed" and float(t[2]) == 1.0 for t in term)
par = run[0][7] == "t" if run else False
print("  info[armA-term]: %s parallel=%s" % ([t[1] + "/" + t[2] for t in term], par))
sys.exit(0 if ok and par else 1)
PYEOF
check "arm A: terminal completed/1.0 and parallel=t" $?

# worker-merge rate proof (see scenario header): W=2, participation on ->
# leader lone-share fraction = 1/D-hat = 1/2.4; a merged view runs at the
# full rate.  Some poll interval must exceed 1.5x the average lone-share
# rate (total rows / 2.4 / total time).
RESULT=$(grep -c . "$WORKDIR/s22fifo.out" >/dev/null; awk 'END{print $0}' "$WORKDIR/s22fifo.out" 2>/dev/null)
TOTAL=$(q "SELECT count(*) FROM dim_dates d, dim_customers c WHERE d.cal_date = c.reg_date" 2>/dev/null || echo 0)
python3 - "$POLLF" "$TOTAL" <<'PYEOF'
import sys
rows = [ln.rstrip("\n").split("\t") for ln in open(sys.argv[1]) if ln.strip()]
run = [(int(r[0]), float(r[4])) for r in rows if len(r) >= 8 and r[1] == "running"]
total = float(sys.argv[2])
if len(run) < 3 or total <= 0:
    print("  info[merge-rate]: insufficient samples (%d) or total=%s" % (len(run), total))
    sys.exit(1)
span_ms = run[-1][0] - run[0][0]
if span_ms <= 0:
    sys.exit(1)
lone_rate = (total / 2.4) / (span_ms / 1000.0)   # tuples/s at leader lone share
best = max((run[i][1] - run[i-1][1]) / ((run[i][0] - run[i-1][0]) / 1000.0)
           for i in range(1, len(run)) if run[i][0] > run[i-1][0])
print("  info[merge-rate]: best=%.0f tuples/s lone-share=%.0f tuples/s ratio=%.2f"
      % (best, lone_rate, best / lone_rate if lone_rate else 0))
sys.exit(0 if best > 1.5 * lone_rate else 1)
PYEOF
check "arm A: worker counters merged (rate above leader lone-share)" $?

# ---- arm B: multi-Gather UNION ALL (no collapse) ----------------------------
QB="SELECT /* s22u2 */ count(*) FROM (
      SELECT c.customer_id FROM dim_customers c, dim_stores WHERE c.seg < 100
      UNION ALL
      SELECT c.customer_id FROM dim_customers c, dim_stores WHERE c.seg < 100
    ) t"
bg_open 9 s22bfifo "$WORKDIR/s22.b.log"
sendq 9 "SET max_parallel_workers_per_gather=2"
sendq 9 "SET enable_parallel_append=off"
sendq 9 "$QB"
PIDB=""
wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s22u2%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
  PIDB=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s22u2%' AND pid <> pg_backend_pid() LIMIT 1")
POLLB="$WORKDIR/s22.b.poll"
if [ -n "$PIDB" ]; then
  poll_progress "$PIDB" 0.12 "$(timeout_scale 240)" "$POLLB"
fi
bg_close 9 s22bfifo
analyze_polls "$POLLB" armB 2 3
check "arm B (2-Gather UNION ALL): no cc/tp collapse, monotonic" $?

finish_scenario
