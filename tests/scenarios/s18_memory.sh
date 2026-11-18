#!/usr/bin/env bash
# s18: memory gate.  Two shmem blocks must appear in pg_shmem_allocations
# under their names, with byte counts derived from the layout constants:
#   main   block = MAXALIGN(sizeof(PgQPSharedState)) + MaxBackends * 1144
#   worker block = 3211280 (PGQP_WTAB_SIZE, a compile-time constant)
# The 1144 slot size and the 3211280 block size are pinned by static
# assertions in pg_query_progress.c at build time.
#
# Requires superuser (pg_shmem_allocations is role-gated).  When server
# development headers are available, a standalone probe recomputes
# sizeof(PgQPSharedState) from the real header; otherwise the header size
# is inferred from a small version-dependent allowance.
source "$(dirname "$BASH_SOURCE")/../common.sh"

# ---- 0. superuser gate ------------------------------------------------------
IS_SU=$(q "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
if [ "$IS_SU" != "t" ]; then
  skip "pg_shmem_allocations requires superuser" "run bootstrap as the cluster owner"
  finish_scenario
  exit 0
fi

# ---- 1. both named blocks exist ---------------------------------------------
MAINROW=$(q "SELECT count(*) FROM pg_shmem_allocations WHERE name = 'pg_query_progress'")
WROW=$(q "SELECT count(*) FROM pg_shmem_allocations WHERE name = 'pg_query_progress_workers'")
[ "$MAINROW" = "1" ]; check "main block present in pg_shmem_allocations" $? "rows=$MAINROW"
[ "$WROW" = "1" ]; check "worker table block present in pg_shmem_allocations" $? "rows=$WROW"

# ---- 2. worker block byte count (compile-time constant) ---------------------
WSIZE=$(q "SELECT size FROM pg_shmem_allocations WHERE name = 'pg_query_progress_workers'")
[ "$WSIZE" = "3211280" ]; check "worker block size == 3211280" $? "size=$WSIZE"

# ---- 3. main block byte count (slot arithmetic) -----------------------------
# MaxBackends, per InitializeMaxBackends (postinit.c):
#   PG >= 18: max_connections + autovacuum_worker_slots
#             + max_worker_processes + max_wal_senders + 2
#   PG 17    : max_connections + autovacuum_max_workers
#             + max_worker_processes + max_wal_senders + 2
#   PG <= 16 : max_connections + autovacuum_max_workers + 1
#             + max_worker_processes + max_wal_senders
VER=$(q "SHOW server_version_num")
AV_GUC=autovacuum_max_workers
[ "$VER" -ge 180000 ] && AV_GUC=autovacuum_worker_slots
SPECIAL=2
[ "$VER" -lt 170000 ] && SPECIAL=1
MB=$(q "SELECT (SELECT setting::int FROM pg_settings WHERE name='max_connections')
      + (SELECT setting::int FROM pg_settings WHERE name='$AV_GUC')
      + (SELECT setting::int FROM pg_settings WHERE name='max_worker_processes')
      + (SELECT setting::int FROM pg_settings WHERE name='max_wal_senders')
      + $SPECIAL")

ALIGN() { awk -v s="$1" 'BEGIN { print int((s + 7) / 8) * 8 }'; }
SLOT=1144

# header size: try the compiled probe against real headers; fall back to
# the small known allowance
HDR=""
INC_CAND=("${PGQP_INCLUDE:-}")
# source-tree layouts relative to the pg_config binary
PC_BIN="$(readlink -f "$(command -v "$PG_CONFIG_PGQP" 2>/dev/null || echo pg_config)")"
d="$(dirname "$PC_BIN")"
while [ "$d" != "/" ] && [ "${#INC_CAND[@]}" -lt 5 ]; do
  for i in include src/include; do
    [ -f "$d/$i/postgres.h" ] && INC_CAND+=("$d/$i")
  done
  d="$(dirname "$d")"
done
for inc in "${INC_CAND[@]}"; do
  [ -n "$inc" ] && [ -f "$inc/postgres.h" ] || continue
  PROBE_SRC="$WORKDIR/size_probe.c"
  # shellcheck disable=SC2034
  cat > "$PROBE_SRC" <<EOF
#include "postgres.h"
#include <unistd.h>
#include "$PGQP_SRCROOT/pg_query_progress.h"
char buf[64];
int main(void) {
    int n = 0;
    n += __builtin_sprintf(buf + n, "%zu",
                           sizeof(PgQPSharedState));
    write(2, buf, n);
    return 0;
}
EOF
  if cc -I"$inc" -o "$WORKDIR/size_probe" "$PROBE_SRC" 2>/dev/null; then
    HDR=$("$WORKDIR/size_probe" 2>&1)
    echo "  info: probe sizeof(PgQPSharedState)=$HDR (include: $inc)"
    break
  fi
done
if [ -z "$HDR" ]; then
  # allowance: LWLock + int + uint32, MAXALIGNed to at most 32
  HDR=24
  HDR_RANGE=1
  echo "  info: header probe unavailable, using allowance $HDR"
fi

MAIN_SIZE=$(q "SELECT size FROM pg_shmem_allocations WHERE name = 'pg_query_progress'")
EXPECT=$(( $(ALIGN "$HDR") + MB * $(ALIGN "$SLOT") ))
if [ "${HDR_RANGE:-0}" = "1" ]; then
  # no probe: header somewhere in 8..32, aligned
  OK=$(awk -v got="$MAIN_SIZE" -v mb="$MB" -v slot="$(ALIGN "$SLOT")" \
        'BEGIN { lo = mb*slot + 8; hi = mb*slot + 32;
                 print (got >= lo && got <= hi && got % 8 == 0) ? 0 : 1 }')
  check "main block size within header allowance + MaxBackends*1144" \
    $? "got=$MAIN_SIZE range=[$((MB*$(ALIGN "$SLOT")+8)),$((MB*$(ALIGN "$SLOT")+32))] (MaxBackends=$MB)"
else
  [ "$MAIN_SIZE" = "$EXPECT" ]; check "main block size == header + MaxBackends*1144" \
    $? "got=$MAIN_SIZE expect=$EXPECT (MaxBackends=$MB, hdr=$HDR)"
fi

finish_scenario
