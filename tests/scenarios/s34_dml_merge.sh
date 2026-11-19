#!/usr/bin/env bash
# s34: MERGE progress (mixed matched/unmatched source).
#  - plan: "Merge on" top node over a join source
#  - view: monotonic, terminal completed/1.0
#  - node accounting: nodes_total equals the EXPLAIN node count (the
#    ModifyTable/Merge node is counted, i.e. one more than an otherwise
#    isomorphic SELECT plan would show); nodes_done terminal value is
#    only bounded below (join row estimates are not exact), never
#    asserted as an equality
#  - RETURNING arm (server_version_num >= 170000 only: the MERGE
#    RETURNING syntax does not exist on older majors): root readouts
#    become live -- plan_rows > 0 and rows_returned counts the rows
#    produced by the actions
source "$(dirname "$BASH_SOURCE")/../common.sh"

N=$(awk -v s="${PGQP_SCALE:-0.1}" 'BEGIN{n=int(250000*s/0.1); if(n<20000)n=20000; if(n>400000)n=400000; print n}')
HALF=$(( N / 2 ))

q "DROP TABLE IF EXISTS s34_t" > /dev/null
q "CREATE TABLE s34_t (k int PRIMARY KEY, v int, pad text)" > /dev/null
q "INSERT INTO s34_t SELECT g, 0, repeat('x', 16) FROM generate_series(1, $HALF) g" > /dev/null
q "ANALYZE s34_t" > /dev/null
check "merge target ready (prefilled=$HALF source=$N)" $?

MERGEQ="MERGE /* s34m */ INTO s34_t t USING (SELECT g AS k, g AS v, repeat('v', 32) AS pad FROM generate_series(1, $N) g) s ON t.k = s.k
  WHEN MATCHED THEN UPDATE SET v = t.v + 1
  WHEN NOT MATCHED THEN INSERT (k, v, pad) VALUES (s.k, s.v, s.pad)"

EX=$(q "EXPLAIN (COSTS OFF) $MERGEQ")
echo "$EX" | grep -q "Merge on"
check "plan top node is Merge on" $?
# EXPLAIN prints bitmap index scan / bitmap and / bitmap or subtrees line
# by line, but the progress walk folds them into their parent (no
# instrument, not counted in nodes_total) -- exclude those lines from
# the comparison base so the assertion below stays valid if the planner
# ever picks a bitmap join path instead of today's hash join.  Non-root
# Materialize is folded the same way (child-driven frac, itself absent
# from nodes_total), so its EXPLAIN line is excluded too (review R-1).
NODES=$(echo "$EX" | grep -E 'Merge on|->' | grep -vcE 'Bitmap (Index Scan|And|Or)|Materialize')
echo "  info: explain nodes=$NODES (bitmap subtree + non-root Materialize lines excluded)"

bg_open 9 s34fifo "$WORKDIR/s34.log"
sendq 9 "SET max_parallel_workers_per_gather=0"
sendq 9 "$MERGEQ"
PID=""
wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s34m%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
  PID=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s34m%' AND pid <> pg_backend_pid() LIMIT 1")
[ -n "$PID" ]; check "leader row visible while running" $? "pid=${PID:-none}"
POLLF="$WORKDIR/s34.poll"
[ -n "$PID" ] && poll_progress "$PID" 0.12 "$(timeout_scale 240)" "$POLLF"
V=$(q "SELECT state, progress, nodes_total, nodes_done FROM pg_query_progress WHERE query LIKE '%s34m%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
bg_close 9 s34fifo

analyze_polls "$POLLF" s34 3 5
check "monotonic, >=5 distinct, no cc/tp collapse" $?

echo "  info: terminal view row: $V (explain nodes=$NODES)"
ST=$(echo "$V" | cut -d'|' -f1); PR=$(echo "$V" | cut -d'|' -f2)
NT=$(echo "$V" | cut -d'|' -f3); ND=$(echo "$V" | cut -d'|' -f4)
[ "$ST" = "completed" ] && [ "$PR" = "1" ]
check "terminal completed/1.0" $? "row=$V"
[ "$NT" -ge "$NODES" ]; check "nodes_total counts the Merge node (>= explain count)" $? "nodes_total=$NT explain=$NODES"
SRC_NODES=$(( NODES - 1 ))
[ "$ND" -ge $(( NT - SRC_NODES )) ]
check "terminal nodes_done >= nodes_total - source nodes (bounded, not equated)" $? "nodes_done=$ND nodes_total=$NT source_nodes=$SRC_NODES"
MC=$(q "SELECT count(*) FROM s34_t")
[ "$MC" = "$N" ]; check "target holds exactly the source keys" $? "rows=$MC expected=$N"
MV=$(q "SELECT count(*) FROM s34_t WHERE v = 1")
[ "$MV" = "$HALF" ]; check "matched rows took the UPDATE action" $? "updated=$MV expected=$HALF"

# ---- RETURNING arm (version-gated) ------------------------------------------
VNUM=$(q "SHOW server_version_num")
if [ "$VNUM" -ge 170000 ]; then
  RETQ="MERGE /* s34r */ INTO s34_t t USING (SELECT g AS k, g AS v FROM generate_series(1, $N) g) s ON t.k = s.k
  WHEN MATCHED THEN UPDATE SET v = t.v + 1
  WHEN NOT MATCHED THEN INSERT (k, v) VALUES (s.k, s.v)
  RETURNING t.k"
  bg_open 9 s34rfifo "$WORKDIR/s34r.log"
  sendq 9 "SET max_parallel_workers_per_gather=0"
  sendq 9 "$RETQ"
  RP=""
  wait_until "$(timeout_scale 15)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s34r%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
    RP=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s34r%' AND pid <> pg_backend_pid() LIMIT 1")
  [ -n "$RP" ] && poll_progress "$RP" 0.12 "$(timeout_scale 240)" "$WORKDIR/s34r.poll"
  VR=$(q "SELECT state, progress, plan_rows, rows_returned FROM pg_query_progress WHERE query LIKE '%s34r%' AND state='completed' ORDER BY last_update DESC LIMIT 1")
  bg_close 9 s34rfifo
  echo "  info[returning]: $VR"
  echo "$VR" | grep -qE "^completed\|1\|[0-9]+\|[0-9]+$"; check "RETURNING arm: terminal completed/1.0" $? "row=$VR"
  PRR=$(echo "$VR" | cut -d'|' -f3); RRR=$(echo "$VR" | cut -d'|' -f4)
  [ "$PRR" -gt 0 ]; check "RETURNING arm: plan_rows is the source estimate (> 0)" $? "plan_rows=$PRR"
  [ "$RRR" -ge "$N" ]; check "RETURNING arm: rows_returned counts action outputs" $? "returned=$RRR source=$N"
else
  skip "MERGE RETURNING arm" "server_version_num=$VNUM (< 170000, syntax unsupported)"
fi

finish_scenario
