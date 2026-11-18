#!/usr/bin/env bash
# s10: slot capacity -- with max_connections=5, the slot array (one slot
# per MaxBackends) must cover every possible session.  Runs its own
# throwaway cluster; the maximum number of concurrent clients the server
# admits is 5, so 4 external workload sessions plus the observing session
# itself cover every possible backend.
source "$(dirname "$BASH_SOURCE")/../common.sh"

PGDATA10="$WORKDIR/s10cluster"
PORT10="$(free_port)"
rm -rf "$PGDATA10"
initdb -D "$PGDATA10" --no-sync --auth=trust > /dev/null 2>&1
cat >> "$PGDATA10/postgresql.auto.conf" <<EOF
shared_preload_libraries = '$PGQP_SO'
max_connections = 5
unix_socket_directories = '$PGDATA10'
EOF
pg_ctl -D "$PGDATA10" -o "-p $PORT10" -l "$PGDATA10/server.log" start -w > /dev/null 2>&1
check "cluster with max_connections=5 started" $?

CONN10=(-h "$PGDATA10" -p "$PORT10" -U postgres -d postgres)
sed "s|MODULE_PATHNAME|$PGQP_SO|g" "$PGQP_SRCROOT/pg_query_progress--1.0.sql" | psql "${CONN10[@]}" -X -q -v ON_ERROR_STOP=1
check "view installed on capacity cluster" $?
psql "${CONN10[@]}" -X -q -v ON_ERROR_STOP=1 -v scale=0.001 -f "$TESTS_DIR/setup.sql" > /dev/null 2>&1
check "workload data loaded" $?

NSESSIONS=4
for i in $(seq 1 $NSESSIONS); do
  mkfifo "$WORKDIR/s10.$i"
  # close earlier fifos' fds in the child (see common.sh bg_open note)
  closes=""
  for j in $(seq 1 $((i-1))); do closes+=" $((8+j))>&-"; done
  eval "psql ${CONN10[*]} -X -q -At -f '$WORKDIR/s10.$i' > '$WORKDIR/s10.$i.log' 2>&1 ${closes} &"
  eval "exec $((8+i))> $WORKDIR/s10.$i"
done
for i in $(seq 1 $NSESSIONS); do
  echo "SELECT count(v) FROM (SELECT x FROM big_table LIMIT 4000) b, LATERAL (SELECT pg_sleep(0.003), b.x AS v) s;" >&$((8+i))
done

sleep "$(timeout_scale 3)"
# The SRF skips the caller's own RUNNING slot, so this query sees exactly
# the 4 external workloads; the observer session itself is tracked (its
# own slot exists) but is filtered as self-noise.
N=$(psql "${CONN10[@]}" -X -At -c "SELECT count(*) FROM pg_query_progress WHERE state='running'")
[ "$N" = "4" ]; check "4/4 external workload backends tracked (observer self-row filtered)" $? "running=$N"
SELF=$(psql "${CONN10[@]}" -X -At -c "SELECT count(*) FROM pg_query_progress WHERE pid = pg_backend_pid() AND state='running'")
[ "$SELF" = "0" ]; check "no phantom running row for the observing session" $? "self_rows=$SELF"

for i in $(seq 1 $NSESSIONS); do
  eval "exec $((8+i))>&-"
done
wait 2>/dev/null
pg_ctl -D "$PGDATA10" stop -m fast > /dev/null 2>&1
rm -rf "$PGDATA10"
finish_scenario
