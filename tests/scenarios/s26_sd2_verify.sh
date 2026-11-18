#!/usr/bin/env bash
# s26 (main branch only): worker-side index instrumentation pairing.
# The three reachable shapes that exercise the injected per-node
# instrument on PARALLEL index scans, on a dedicated indexed table:
#   arm 1  Parallel Index Only Scan  : SELECT count(k)
#   arm 2  Parallel Index Scan       : SELECT count(rid) (seqscan/bitmap off)
#   arm 3  Parallel Bitmap Heap Scan <- Bitmap Index Scan: count(rid) WHERE k <
# Per arm x2 runs (fifo-held session + concurrent view polling): EXPLAIN
# shape grep, correct result, zero crash, terminal completed/1.0,
# parallel=t; pooled server-log delta free of signal/WARNING/PANIC.
# EXPLAIN ANALYZE double-count guard: top-node actual rows identical with
# track=on vs track=off.
source "$(dirname "$BASH_SOURCE")/../common.sh"

loglines() { [ -f "$PGDATA/server.log" ] && wc -l < "$PGDATA/server.log" || echo 0; }
LOGBASE=$(loglines)

# ---- dedicated indexed table (default 800k rows, PGQP_S26_ROWS override) --
NROWS="${PGQP_S26_ROWS:-$(awk -v s="${PGQP_SCALE:-0.1}" 'BEGIN {printf "%d", 8000000 * s}')}"
psql -X -q -At -v ON_ERROR_STOP=1 -c "
DROP TABLE IF EXISTS sdx_tab;
CREATE TABLE sdx_tab AS
  SELECT g AS rid, (g % 1000)::int AS k, repeat('x', 8) AS pad
  FROM generate_series(1, $NROWS) g;
CREATE INDEX sdx_tab_k_idx ON sdx_tab (k);
ANALYZE sdx_tab;" > "$WORKDIR/s26.build.log" 2>&1
check "sdx_tab built ($NROWS rows, index on k)" $?
N=$(q "SELECT count(*) FROM sdx_tab")
[ "$N" = "$NROWS" ]; check "sdx_tab row count == $NROWS" $? "n=$N"

run_shape() {                # run_shape <label> <patterns,|> <sets> <query> <expected> [runs]
  local label="$1" pats="$2" sets="$3" query="$4" expect="$5" runs="${6:-2}"
  local ex rc=0 p pid i res_ok=0 pollf="$WORKDIR/s26.$label.poll"
  ex=$(psql -X -q -At -c "$sets" -c "EXPLAIN (COSTS OFF) $query" 2>&1)
  echo "$ex" > "$WORKDIR/s26.$label.explain.txt"
  local IFS=','
  for p in $pats; do echo "$ex" | grep -q "$p" || rc=1; done
  unset IFS
  check "$label plan: contains [$pats]" $rc
  # expected result computed independently (range width x series x rows/1000)
  : > "$pollf"
  for i in $(seq 1 "$runs"); do
    bg_open 9 "s26${label}${i}" "$WORKDIR/s26.$label.$i.log"
    sendq 9 "$sets"
    sendq 9 "$query"
    pid=""
    wait_until "$(timeout_scale 6)" "q \"SELECT 1 FROM pg_query_progress WHERE state='running' AND query LIKE '%s26${label}%' AND pid <> pg_backend_pid()\" | grep -q 1" && \
      pid=$(q "SELECT pid FROM pg_query_progress WHERE state='running' AND query LIKE '%s26${label}%' AND pid <> pg_backend_pid() LIMIT 1")
    if [ -n "$pid" ]; then
      poll_progress "$pid" 0.1 "$(timeout_scale 120)" "$pollf.tmp"
      cat "$pollf.tmp" >> "$pollf" 2>/dev/null || true
    fi
    bg_close 9 "s26${label}${i}"
    GOT=$(tail -1 "$WORKDIR/s26.$label.$i.log" 2>/dev/null)
    [ "$GOT" = "$expect" ] || { res_ok=1; echo "  info[$label run$i]: got=$GOT expect=$expect"; }
  done
  check "$label x$runs: correct result, no crash, connection alive" $res_ok
  python3 - "$pollf" "$label" <<'PYEOF'
import sys
pollf, label = sys.argv[1], sys.argv[2]
rows = [ln.rstrip("\n").split("\t") for ln in open(pollf) if ln.strip()]
rows = [r for r in rows if len(r) >= 7]
segments, cur = [], []
for r in rows:
    cur.append(r)
    if r[1] != "running":
        segments.append(cur)
        cur = []
if cur:
    segments.append(cur)
dec = 0
maxp = -1.0
terms = []
for seg in segments:
    prog = [float(r[2]) for r in seg if r[1] == "running"]
    dec += sum(1 for i in range(1, len(prog)) if prog[i] < prog[i-1] - 1e-9)
    if prog:
        maxp = max(maxp, max(prog))
    terms += [t for t in seg if t[1] != "running"]
print("  info[%s]: polls=%d segments=%d max_prog=%.4f dec(within-run)=%d terms=%s" %
      (label, len(rows), len(segments), maxp, dec, [t[1] + "/" + t[2] for t in terms]))
sys.exit(0 if dec == 0 and terms
         and all(t[1] == "completed" and t[2] == "1" for t in terms) else 1)
PYEOF
  check "$label view: monotonic, terminal completed/1.0" $?
  PAR=$(grep -m1 "running" "$pollf" | awk -F'\t' '{print $7}')
  [ "$PAR" = "t" ]; check "$label view: parallel = t" $? "parallel=$PAR"
}

# range predicate + generate_series cross: the range keeps the index path
# cheaper than a full parallel seq scan, the cross join stretches runtime
# past the publish cadence so mid-flight samples are observable
K_HI="${PGQP_S26_KHI:-599}"
K_LO=100
Q_IOS="SELECT /* s26ios */ count(k) FROM sdx_tab c, generate_series(1,6) g WHERE c.k BETWEEN $K_LO AND $K_HI"
Q_IS="SELECT /* s26is */ count(rid) FROM sdx_tab c, generate_series(1,6) g WHERE c.k BETWEEN $K_LO AND $K_HI"
Q_BHS="SELECT /* s26bhs */ count(rid) FROM sdx_tab c, generate_series(1,6) g WHERE c.k BETWEEN $K_LO AND 349"
EXP_FULL=$(q "SELECT count(*) FROM sdx_tab WHERE k BETWEEN $K_LO AND $K_HI")
EXP_BHS=$(q "SELECT count(*) FROM sdx_tab WHERE k BETWEEN $K_LO AND 349")

run_shape ios "Parallel Index Only Scan" \
  "SET max_parallel_workers_per_gather=2; SET enable_bitmapscan=off; SET enable_seqscan=off" "$Q_IOS" "$((EXP_FULL * 6))" 2

run_shape is "Parallel Index Scan" \
  "SET max_parallel_workers_per_gather=2; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; SET enable_seqscan=off" "$Q_IS" "$((EXP_FULL * 6))" 2

run_shape bhs "Parallel Bitmap Heap Scan,Bitmap Index Scan" \
  "SET max_parallel_workers_per_gather=2" "$Q_BHS" "$((EXP_BHS * 6))" 2

# ---- EXPLAIN ANALYZE double-count guard -------------------------------------
ea_arm() {                   # ea_arm <label> <sets> <query>
  local label="$1" sets="$2" query="$3" a b rowsa rowsb
  a=$(psql -X -q -At -c "$sets" -c "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) $query" 2>&1)
  b=$(psql -X -q -At -c "SET pg_query_progress.track=off" -c "$sets" -c "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) $query" 2>&1)
  { echo "== track=on:"; echo "$a"; echo "== track=off:"; echo "$b"; } > "$WORKDIR/s26_${label}_ea.txt"
  rowsa=$(echo "$a" | grep -o "rows=[0-9.]* loops=[0-9]*" | sort | md5sum | cut -d' ' -f1)
  rowsb=$(echo "$b" | grep -o "rows=[0-9.]* loops=[0-9]*" | sort | md5sum | cut -d' ' -f1)
  [ -n "$rowsa" ] && [ "$rowsa" = "$rowsb" ]
  check "EA/$label: actual rows multiset identical track on/off (${rowsa:0:8})" $?
}
ea_arm ios "SET max_parallel_workers_per_gather=2; SET enable_bitmapscan=off; SET enable_seqscan=off" "$Q_IOS"
ea_arm is "SET max_parallel_workers_per_gather=2; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; SET enable_seqscan=off" "$Q_IS"
ea_arm bhs "SET max_parallel_workers_per_gather=2" "$Q_BHS"

# ---- pooled server-log guard ------------------------------------------------
sleep 1
DELTA=$(tail -n +"$((LOGBASE+1))" "$PGDATA/server.log" 2>/dev/null)
BAD=$(echo "$DELTA" | grep -ci "signal\|WARNING\|PANIC\|Segmentation" || true)
[ "$BAD" = "0" ]; check "server log delta: zero signal/WARNING/PANIC across all arms" $? "bad_lines=${BAD:-0}"

finish_scenario
