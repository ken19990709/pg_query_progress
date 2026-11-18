#!/usr/bin/env bash
# s23: operator coverage matrix (trimmed).  One runnable minimal shape per
# operator family: seq scan, index scan, index-only scan, bitmap heap
# scan, parallel hash join, gather merge, sort, aggregate, setop, append.
# Per arm: EXPLAIN shape grep, correct result (cross-checked against an
# independently computed count), terminal completed/1.0, and for the
# long-running arms a polled monotonicity check.  Marker comments make
# each arm's row uniquely matchable in the view.
source "$(dirname "$BASH_SOURCE")/../common.sh"

psql -X -q -v ON_ERROR_STOP=1 -v scale="${PGQP_SCALE:-0.1}" -f "$TESTS_DIR/setup.sql" > /dev/null 2>&1
check "workload tables ready" $?

NB=$(q "SELECT count(*) FROM big_table")

# run_arm <label> <patterns,|> <sets> <query> <expected> [poll:0|1]
run_arm() {
  local label="$1" pats="$2" sets="$3" query="$4" expect="$5" poll="${6:-0}"
  local ex rc=0 p pid="" IFS=','
  ex=$(psql -X -q -At -c "$sets" -c "EXPLAIN (COSTS OFF) $query" 2>&1)
  for p in $pats; do echo "$ex" | grep -q "$p" || rc=1; done
  unset IFS
  check "$label plan: contains [$pats]" $rc

  local pollf="$WORKDIR/s23.$label.poll" log="$WORKDIR/s23.$label.log"
  : > "$pollf"
  bg_open 9 "s23$label" "$log"
  [ -n "$sets" ] && sendq 9 "$sets"
  sendq 9 "$query"
  if [ "$poll" = "1" ]; then
    if wait_until "$(timeout_scale 8)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%${label}%' AND pid <> pg_backend_pid()\" | grep -q 1"; then
      pid=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%${label}%' AND pid <> pg_backend_pid() LIMIT 1")
    fi
    [ -n "$pid" ] && poll_progress "$pid" 0.1 "$(timeout_scale 120)" "$pollf"
  fi
  wait_until "$(timeout_scale 120)" "q \"SELECT 1 FROM pg_query_progress WHERE query LIKE '%${label}%' AND state='completed' AND pid <> pg_backend_pid()\" | grep -q 1"
  P=$(q "SELECT progress FROM pg_query_progress WHERE query LIKE '%${label}%' AND state='completed' AND pid <> pg_backend_pid() ORDER BY last_update DESC LIMIT 1")
  [ "$P" = "1" ]; check "$label: terminal completed/1.0" $? "progress=${P:-none}"
  bg_close 9 "s23$label"
  grep -q "^${expect}$" "$log"
  check "$label: correct result ($expect)" $? "log=$(head -1 "$log")"

  if [ "$poll" = "1" ] && [ -s "$pollf" ]; then
    analyze_polls "$pollf" "$label" 1 3
    check "$label: mid-run monotonic, no cc/tp collapse" $?
  fi
}

# seq scan + aggregate (stretched slightly so mid-run polling is possible)
run_arm seqagg "Seq Scan" "SET max_parallel_workers_per_gather=0" \
  "SELECT /* s23seqagg */ count(*) FROM (SELECT x FROM big_table) b, LATERAL (SELECT pg_sleep(0.000004), b.x AS v) s" \
  "$NB" 1

# plain index scan / index-only scan / bitmap heap scan (t1 x t2 shapes)
run_arm idx "Index Scan,Nested Loop" "SET enable_seqscan=off; SET enable_hashjoin=off; SET enable_mergejoin=off" \
  "SELECT /* s23idx */ count(*) FROM t1 JOIN t2 ON t1.k = t2.k WHERE t1.id < 4" \
  "$(q "SELECT count(*) FROM t1 JOIN t2 ON t1.k = t2.k WHERE t1.id < 4")" 0

run_arm idxonly "Index Only Scan" "SET enable_seqscan=off; SET enable_indexscan=off; SET enable_bitmapscan=off" \
  "SELECT /* s23idxonly */ count(*) FROM t1 WHERE k < 10" \
  "$(q "SELECT count(*) FROM t1 WHERE k < 10")" 0

run_arm bitmap "Bitmap Heap Scan" "SET enable_indexscan=off; SET enable_seqscan=off" \
  "SELECT /* s23bitmap */ count(*) FROM t1 WHERE k < 1000" \
  "$(q "SELECT count(*) FROM t1 WHERE k < 1000")" 0

# parallel hash join (stretched via generate_series cross)
run_arm phj "Parallel Hash Join,Gather" \
  "SET max_parallel_workers_per_gather=2" \
  "SELECT /* s23phj */ count(*) FROM t1 a JOIN t2 b ON a.k = b.k, generate_series(1, 60) g WHERE a.id < 20000" \
  "$(q "SELECT count(*) FROM t1 a JOIN t2 b ON a.k = b.k, generate_series(1, 60) g WHERE a.id < 20000")" 1

# gather merge (ORDER BY parallel sort)
run_arm gm "Gather Merge,Sort" \
  "SET max_parallel_workers_per_gather=2" \
  "SELECT /* s23gm */ count(x) FROM (SELECT b.x FROM big_table b ORDER BY b.x) s" \
  "$NB" 1

# sort (serial)
run_arm sort "Sort" "SET max_parallel_workers_per_gather=0" \
  "SELECT /* s23sort */ count(x) FROM (SELECT x FROM big_table ORDER BY x DESC) s" \
  "$NB" 0

# grouped aggregate
run_arm agg "Aggregate" "SET max_parallel_workers_per_gather=0" \
  "SELECT /* s23agg */ count(*) FROM (SELECT y, count(*) FROM big_table GROUP BY y) s" \
  "$(q "SELECT count(DISTINCT y) FROM big_table")" 0

# setop (EXCEPT)
run_arm setop "SetOp" "SET max_parallel_workers_per_gather=0" \
  "SELECT /* s23setop */ count(*) FROM (SELECT x FROM big_table WHERE x < 50000 EXCEPT SELECT x FROM big_table WHERE x < 25000) s" \
  "25000" 0

# append (UNION ALL both sides)
run_arm append "Append" "SET max_parallel_workers_per_gather=0" \
  "SELECT /* s23append */ count(*) FROM (SELECT x FROM big_table WHERE x < 1000 UNION ALL SELECT x FROM big_table WHERE x > 799000) s" \
  "$(q "SELECT (SELECT count(*) FROM big_table WHERE x < 1000) + (SELECT count(*) FROM big_table WHERE x > 799000)")" 0

finish_scenario
