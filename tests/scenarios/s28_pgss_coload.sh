#!/usr/bin/env bash
# s28: shared-preload co-existence with a legacy-shmem extension.
# pg_stat_statements loaded FIRST (its shmem request hook sits earlier in
# the chain), pg_query_progress second: the postmaster calls only the end
# of the shmem_request hook chain, so our hook must forward to the
# previous one -- dropping the forwarding silently discards the earlier
# extension's shared-memory request and the server refuses to start
# (FATAL: requested tranche is not registered).  Both load orders are
# exercised; after startup, both views must be functional.
source "$(dirname "$BASH_SOURCE")/../common.sh"

# locate pg_stat_statements: env override, then the bootstrapped pkglibdir
PGSS_SO="${PGQP_PGSS_SO:-}"
if [ -z "$PGSS_SO" ] && [ -n "${PGQP_PKGLIB:-}" ] && [ -f "$PGQP_PKGLIB/pg_stat_statements.so" ]; then
  PGSS_SO="$PGQP_PKGLIB/pg_stat_statements.so"
fi
if [ -z "$PGSS_SO" ]; then
  cand="$("$PG_CONFIG_PGQP" --pkglibdir 2>/dev/null)/pg_stat_statements.so"
  [ -f "$cand" ] && PGSS_SO="$cand"
fi
if [ -z "$PGSS_SO" ] || [ ! -f "$PGSS_SO" ]; then
  skip "pg_stat_statements library not found" "set PGQP_PGSS_SO"
  finish_scenario
  exit 0
fi
echo "  info: pg_stat_statements = $PGSS_SO"

run_variant() {                 # run_variant <order: pgss_first|pgqp_first>
  local order="$1" pgdata="$WORKDIR/s28.$order" port preload
  port="$(free_port)"
  rm -rf "$pgdata"
  initdb -D "$pgdata" -U postgres --no-sync --auth=trust > /dev/null 2>&1
  if [ "$order" = "pgss_first" ]; then
    preload="'$PGSS_SO, $PGQP_SO'"
  else
    preload="'$PGQP_SO, $PGSS_SO'"
  fi
  cat >> "$pgdata/postgresql.auto.conf" <<EOF
shared_preload_libraries = $preload
unix_socket_directories = '$pgdata'
EOF
  pg_ctl -D "$pgdata" -o "-p $port" -l "$pgdata/server.log" start -w > /dev/null 2>&1
  check "server starts with both libraries preloaded ($order)" $?
  if [ ! -f "$pgdata/postmaster.pid" ]; then
    grep -m2 "FATAL\|PANIC" "$pgdata/server.log" 2>/dev/null
    rm -rf "$pgdata"
    return 0
  fi

  local conn=(-h "$pgdata" -p "$port" -U postgres -d postgres)
  sed "s|MODULE_PATHNAME|$PGQP_SO|g" "$PGQP_SRCROOT/pg_query_progress--1.0.sql" \
    | psql "${conn[@]}" -X -q 2> "$WORKDIR/s28.$order.install.log"
  psql "${conn[@]}" -X -q -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" > /dev/null 2>&1

  # pg_query_progress functional: tracked query reaches completed/1.0
  psql "${conn[@]}" -X -q -At \
    -c "SET max_parallel_workers_per_gather=0" \
    -c "SELECT count(*), sum(x + 1) FROM big_table" > /dev/null 2>&1
  P=$(psql "${conn[@]}" -X -At -c "SELECT round(progress::numeric,6) FROM pg_query_progress WHERE state='completed' ORDER BY last_update DESC LIMIT 1")
  [ "$P" = "1.000000" ]; check "pg_query_progress view functional ($order)" $? "progress=${P:-none}"

  # pg_stat_statements functional: it observed the query
  C=$(psql "${conn[@]}" -X -At -c "SELECT calls FROM pg_stat_statements WHERE query LIKE '%sum(x + 1)%' LIMIT 1")
  [ "$C" -ge 1 ] 2>/dev/null; check "pg_stat_statements view functional ($order)" $? "calls=${C:-none}"

  # both shared-memory blocks present alongside pgss's own
  B=$(psql "${conn[@]}" -X -At -c "SELECT count(*) FROM pg_shmem_allocations WHERE name IN ('pg_query_progress','pg_query_progress_workers')")
  [ "$B" = "2" ]; check "both extension blocks in pg_shmem_allocations ($order)" $? "rows=$B"

  pg_ctl -D "$pgdata" stop -m fast > /dev/null 2>&1
  rm -rf "$pgdata"
}

run_variant pgss_first
run_variant pgqp_first
finish_scenario
