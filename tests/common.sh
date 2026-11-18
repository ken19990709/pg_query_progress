#!/usr/bin/env bash
# tests/common.sh -- shared helpers for the scenario scripts.
#
# Environment contract (written by tests/bootstrap.sh into the file named
# by PGQP_ENV, which this file sources):
#   PGHOST/PGPORT/PGUSER/PGDATABASE   connection for the bootstrapped instance
#   PGQP_SO          absolute path of the built shared library
#   PGQP_BINDIR      postgres binaries (initdb, pg_ctl, postgres, psql)
#   PGDATA           the temporary cluster's data directory
#   PGQP_SRCROOT     repository root (source of the .sql install script)
#   PGQP_SCALE       data scale factor (see tests/setup.sql)
#   PGQP_TOLERANCE   timing tolerance multiplier for slow machines (>= 1)
#
# Long-running sessions are driven through fifos so the backend stays alive
# (and its slot observable) between statements:
#   bg_open 9   myfifo   out.log     # open session on fd 9
#   bg_send 9   "SELECT 1;"          # feed a statement
#   bg_close 9  myfifo               # close and reap
# psql output lands in out.log (poll it / grep it for assertions).

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO_DIR="$TESTS_DIR/scenarios"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
WORKDIR="$(mktemp -d -t pgqp-scenario.XXXXXX)"

cleanup_common() {
  local f
  for f in "$WORKDIR"/open.*; do
    [ -e "$f" ] || continue
    local fd
    fd="$(cat "$f")"
    eval "exec ${fd}>&-" 2>/dev/null || true
    rm -f "$f"
  done
  wait 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup_common EXIT

if [ -z "${PGQP_ENV:-}" ]; then
  PGQP_ENV="$TESTS_DIR/.pgqp_env.sh"
fi
if [ ! -f "$PGQP_ENV" ]; then
  echo "common: $PGQP_ENV missing (run tests/bootstrap.sh first)" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$PGQP_ENV"
export PATH="$PGQP_BINDIR:$PATH"
PGQP_TOLERANCE="${PGQP_TOLERANCE:-1}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

check() {                       # check <description> <exit(0=ok)> [detail]
  if [ "$2" = "0" ]; then
    echo "  PASS: $1${3:+ ($3)}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  FAIL: $1${3:+ ($3)}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

skip() {                        # skip <description> [detail]
  echo "  SKIP: $1${2:+ ($2)}"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

finish_scenario() {
  echo "scenario result: PASS=$PASS_COUNT FAIL=$FAIL_COUNT SKIP=$SKIP_COUNT"
  [ "$FAIL_COUNT" = "0" ]
}

q() {                           # q <sql> -> one-line psql result
  psql -X -At -v ON_ERROR_STOP=0 -c "$1" 2>&1
}

# free_port: pick a free TCP port via a bind(0) probe.  Scenarios that
# bootstrap their own clusters use this instead of any fixed port.
free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

bg_open() {                     # bg_open <fd> <name> <logfile>
  local fd="$1" name="$2" log="$3"
  local closers="" f dfd
  # Close previously opened fifo fds in the new psql: background jobs inherit
  # open fds, and a psql holding another session's fifo write end would keep
  # that fifo from ever seeing EOF (bg_close would hang forever).
  for f in "$WORKDIR"/open.*; do
    [ -e "$f" ] || continue
    dfd=$(cat "$f")
    closers+=" ${dfd}>&-"
  done
  mkfifo "$WORKDIR/$name"
  eval "psql -X -q -At -f '$WORKDIR/$name' > '$log' 2>&1 ${closers} & echo \$! > '$WORKDIR/pid.$name'"
  eval "exec ${fd}> '$WORKDIR/$name'"
  echo "$fd" > "$WORKDIR/open.$name"
}

bg_send() {                     # bg_send <fd> <sql>
  echo "$2" >&"$1"
}

sendq() {                       # bg_send with mandatory statement terminator
  local stmt="${2%;}"           # (psql -f fifo buffers input until ;)
  bg_send "$1" "$stmt;"
}

bg_close() {                    # bg_close <fd> <name>
  local pid
  eval "exec $1>&-"
  pid=$(cat "$WORKDIR/pid.$2" 2>/dev/null)
  rm -f "$WORKDIR/open.$2" "$WORKDIR/pid.$2"
  # wait only for THIS session: a bare `wait` would block on every other
  # fifo session whose writer fd is still open (deadlock)
  [ -n "$pid" ] && wait "$pid" 2>/dev/null
  return 0
}

bg_open_split() {               # bg_open_split <fd> <name>: stdout/stderr apart
  local fd="$1" name="$2"
  local closers="" f dfd
  for f in "$WORKDIR"/open.*; do
    [ -e "$f" ] || continue
    dfd=$(cat "$f")
    closers+=" ${dfd}>&-"
  done
  mkfifo "$WORKDIR/$name"
  eval "psql -X -q -At -f '$WORKDIR/$name' > '$WORKDIR/$name.out' ${closers} 2> '$WORKDIR/$name.err' & echo \$! > '$WORKDIR/pid.$name'"
  eval "exec ${fd}> '$WORKDIR/$name'"
  echo "$fd" > "$WORKDIR/open.$name"
}

# wait_until <timeout_s> <shell-condition...> -- poll until true
wait_until() {
  local timeout="$1"; shift
  local waited=0
  while ! eval "$*" > /dev/null 2>&1; do
    sleep 0.2
    waited=$(awk -v w=$waited -v s=0.2 'BEGIN {print w+s}')
    [ "$(awk -v w=$waited -v t=$timeout 'BEGIN {print (w>=t)?1:0}')" = "1" ] && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# View polling: poll_progress <pid> <interval_s> <timeout_s> <outfile>
# Writes tab-separated samples: epoch_ms state progress completed_cost
# tuples_processed rows_returned parallel, one per poll, until the row
# leaves 'running' (or timeout).
# ---------------------------------------------------------------------------
poll_progress() {
  python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import os, sys, time
pid, iv, tmo, out = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
import subprocess
sql = ("SELECT state, progress, completed_cost, tuples_processed, "
       "rows_returned, parallel FROM pg_query_progress WHERE pid = %d" % pid)
deadline = time.time() + tmo
with open(out, "w") as f:
    while time.time() < deadline:
        p = subprocess.run(["psql", "-X", "-At", "-F", "\t", "-c", sql],
                           capture_output=True, text=True)
        line = p.stdout.strip()
        if line:
            f.write("%d\t%s\n" % (int(time.time() * 1000), line))
            f.flush()
            if not line.startswith("running"):
                break
        time.sleep(iv)
PYEOF
}

# analyze_polls <outfile> <label> <min_strict_increments> <min_distinct>:
# running samples must be monotonic in progress/completed_cost/
# tuples_processed, with enough strict growth and distinct values.
analyze_polls() {
  python3 - "$@" <<'PYEOF'
import sys
out, label, mins, mindist = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rows = [ln.rstrip("\n").split("\t") for ln in open(out) if ln.strip()]
run = [r for r in rows if len(r) >= 7 and r[1] == "running"]
prog = [float(r[2]) for r in run]
cc = [float(r[3]) for r in run]
tp = [float(r[4]) for r in run]
def dec(v): return sum(1 for i in range(1, len(v)) if v[i] < v[i-1] - 1e-9)
def incs(v): return sum(1 for i in range(1, len(v)) if v[i] > v[i-1] + 1e-9)
term = [r for r in rows if len(r) >= 7 and r[1] != "running"]
print("  info[%s]: samples=%d running=%d distinct_prog=%d dec(prog/cc/tp)=%d/%d/%d "
      "inc(cc/tp)=%d/%d term=%s" %
      (label, len(rows), len(run), len(set(prog)), dec(prog), dec(cc), dec(tp),
       incs(cc), incs(tp), term[-1][1] if term else "none"))
sys.exit(0 if (dec(prog) == 0 and dec(cc) == 0 and dec(tp) == 0
               and incs(cc) >= mins and incs(tp) >= mins
               and len(set(prog)) >= mindist) else 1)
PYEOF
}

# ---------------------------------------------------------------------------
# Bar-frame helpers (all operate on a psql stderr capture file).
# Frame shape (see pgqp_bar_frame): "[cells] 12.3% 1.5s eta 10.7s nodes 2/5 tuples 1.2K"
# ---------------------------------------------------------------------------
bar_count() {                   # bar_count <file> -> number of frames
  grep -ac "NOTICE" "$1" 2>/dev/null || true
}

bar_percents() {                # bar_percents <file> -> one percent per line
  python3 - "$1" <<'PYEOF'
import re, sys
for ln in open(sys.argv[1], "rb"):
    if b"NOTICE" in ln:
        m = re.search(rb"\] ([0-9.]+)%", ln)
        if m:
            print(m.group(1).decode())
PYEOF
}

bar_first_elapsed() {           # bar_first_elapsed <file> -> ""|<seconds>
  python3 - "$1" <<'PYEOF'
import re, sys
with open(sys.argv[1], "rb") as f:
    for ln in f:
        if b"NOTICE" in ln:
            m = re.search(rb"\] [0-9.]+% ([0-9.]+)s", ln)
            print(m.group(1).decode() if m else "")
            break
    else:
        print("")
PYEOF
}

bar_monotonic() {               # bar_monotonic <file> -> violation count
  python3 - "$1" <<'PYEOF'
import re, sys
pcts = []
for ln in open(sys.argv[1], "rb"):
    if b"NOTICE" in ln:
        m = re.search(rb"\] ([0-9.]+)%", ln)
        if m:
            pcts.append(float(m.group(1)))
print(sum(1 for i in range(1, len(pcts)) if pcts[i] < pcts[i-1] - 1e-9))
PYEOF
}

bar_lastdone() {                # bar_lastdone <file> -> 0 iff last frame is done
  python3 - "$1" <<'PYEOF'
import sys
last = b""
for ln in open(sys.argv[1], "rb"):
    if b"NOTICE" in ln:
        last = ln
sys.exit(0 if b"100.0% done" in last else 1)
PYEOF
}

bar_clean_stdout() {            # bar_clean_stdout <file>: 0 iff no bar bytes
  ! grep -qP '[\x80-\xFF]' "$1" 2>/dev/null
}

# timeout_scale <seconds>: apply PGQP_TOLERANCE to a timeout value
timeout_scale() {
  awk -v t="$1" -v m="$PGQP_TOLERANCE" 'BEGIN { print int(t * m + 0.5) }'
}
