#!/usr/bin/env bash
# s07: auto_explain coexistence (both load orders).  Builds its own two
# throwaway clusters with both libraries preloaded and checks that progress
# publishing stays live while auto_explain (log_analyze=on) instruments the
# same query.  Skips when no auto_explain shared library can be located.
source "$(dirname "$BASH_SOURCE")/../common.sh"

# locate auto_explain: env override, then pg_config pkglibdir
AE_SO="${PGQP_AUTO_EXPLAIN_SO:-}"
if [ -z "$AE_SO" ]; then
  cand="$("$PG_CONFIG_PGQP" --pkglibdir 2>/dev/null)/auto_explain.so"
  [ -f "$cand" ] && AE_SO="$cand"
fi
if [ -z "$AE_SO" ] || [ ! -f "$AE_SO" ]; then
  skip "auto_explain library not found" "set PGQP_AUTO_EXPLAIN_SO"
  finish_scenario
  exit 0
fi
echo "  info: auto_explain = $AE_SO"

run_variant() {                 # run_variant <order: qp_first|ae_first>
  local order="$1" pgdata="$WORKDIR/s7.$order" port
  port="$(free_port)"
  rm -rf "$pgdata"
  initdb -D "$pgdata" --no-sync --auth=trust > /dev/null 2>&1
  if [ "$order" = "qp_first" ]; then
    PRELOAD="'$PGQP_SO, $AE_SO'"
  else
    PRELOAD="'$AE_SO, $PGQP_SO'"
  fi
  cat >> "$pgdata/postgresql.auto.conf" <<EOF
shared_preload_libraries = $PRELOAD
auto_explain.log_min_duration = 0
auto_explain.log_analyze = on
unix_socket_directories = '$pgdata'
EOF
  pg_ctl -D "$pgdata" -o "-p $port" -l "$pgdata/server.log" start -w > /dev/null 2>&1
  check "cluster started ($order)" $?

  local conn=(-h "$pgdata" -p "$port" -U postgres -d postgres)
  sed "s|MODULE_PATHNAME|$PGQP_SO|g" "$PGQP_SRCROOT/pg_query_progress--1.0.sql" \
    | psql "${conn[@]}" -X -q
  psql "${conn[@]}" -X -q -v ON_ERROR_STOP=1 -v scale=0.02 \
    -f "$TESTS_DIR/setup.sql" > /dev/null 2>&1

  # Drive a multi-second tracked query through a fifo-held session and
  # poll mid-run: progress must be actively published WHILE auto_explain
  # instruments the same query.
  local fifo="$WORKDIR/s7.$order.fifo"
  rm -f "$fifo"; mkfifo "$fifo"
  psql "${conn[@]}" -X -q -At -f "$fifo" > "$WORKDIR/s7.$order.query.log" 2>&1 &
  local qpid=$!
  exec 7> "$fifo"
  echo "SELECT count(*) FROM (SELECT x FROM big_table LIMIT 3000) b, LATERAL (SELECT pg_sleep(0.003), b.x AS v) s;" >&7
  wait_until "$(timeout_scale 15)" "psql ${conn[*]} -X -At -c \"SELECT 1 FROM pg_query_progress WHERE state='running' AND pid <> pg_backend_pid()\" | grep -q 1"
  P=$(psql "${conn[@]}" -X -At -c "SELECT count(*) FROM pg_query_progress WHERE state IN ('running','completed') AND pid <> pg_backend_pid()" 2>/dev/null)
  wait_until "$(timeout_scale 20)" "psql ${conn[*]} -X -At -c \"SELECT 1 FROM pg_query_progress WHERE state='completed' AND pid <> pg_backend_pid()\" | grep -q 1"
  P2=$(psql "${conn[@]}" -X -At -c "SELECT round(progress::numeric,6) FROM pg_query_progress WHERE state='completed' AND pid <> pg_backend_pid()" 2>/dev/null)
  exec 7>&-; wait "$qpid" 2>/dev/null
  case "$P" in ''|*[!0-9]*) P=0 ;; esac
  [ "$P" -ge 1 ]; check "progress view active with auto_explain ($order)" $? "rows=$P"
  [ "$P2" = "1.000000" ]; check "tracked query completes 1.0 under auto_explain ($order)" $? "progress=$P2"

  AE=$(grep -c "actual time" "$pgdata/server.log")
  [ "$AE" -ge 1 ]; check "auto_explain ANALYZE rows logged ($order)" $? "matches=$AE"

  pg_ctl -D "$pgdata" stop -m fast > /dev/null 2>&1
  rm -rf "$pgdata"
}

run_variant qp_first
run_variant ae_first
finish_scenario
