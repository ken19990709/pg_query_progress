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
if [ -n "${PGQP_INCLUDE:-}" ] && [ -f "$PGQP_INCLUDE/postgres.h" ]; then
  PROBE_SRC="$WORKDIR/size_probe.c"
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
  if cc -I"$PGQP_INCLUDE" -o "$WORKDIR/size_probe" "$PROBE_SRC" 2>/dev/null; then
    HDR=$("$WORKDIR/size_probe" 2>&1)
    echo "  info: probe sizeof(PgQPSharedState)=$HDR"
  fi
fi
if [ -z "$HDR" ]; then
  HDR=24          # allowance: LWLock + int + uint32, MAXALIGNed
  echo "  info: header probe unavailable, using allowance $HDR"
fi

MAIN_SIZE=$(q "SELECT size FROM pg_shmem_allocations WHERE name = 'pg_query_progress'")
EXPECT=$(( $(ALIGN "$HDR") + MB * $(ALIGN "$SLOT") ))
[ "$MAIN_SIZE" = "$EXPECT" ]; check "main block size == header + MaxBackends*1144" \
  $? "got=$MAIN_SIZE expect=$EXPECT (MaxBackends=$MB, hdr=$HDR)"

finish_scenario
