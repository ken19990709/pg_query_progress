#!/usr/bin/env bash
# s12: loading the library without preload -- the view must return an
# empty set with a WARNING (once per session), no crash.  Uses its own
# non-preload throwaway cluster.
source "$(dirname "$BASH_SOURCE")/../common.sh"

PGDATA12="$WORKDIR/s12cluster"
PORT12="$(free_port)"
rm -rf "$PGDATA12"
initdb -D "$PGDATA12" --no-sync --auth=trust > /dev/null 2>&1
cat >> "$PGDATA12/postgresql.auto.conf" <<EOF
unix_socket_directories = '$PGDATA12'
EOF
pg_ctl -D "$PGDATA12" -o "-p $PORT12" -l "$PGDATA12/server.log" start -w > /dev/null 2>&1
check "non-preload cluster started" $?

CONN12=(-h "$PGDATA12" -p "$PORT12" -U postgres -d postgres)
sed "s|MODULE_PATHNAME|$PGQP_SO|g" "$PGQP_SRCROOT/pg_query_progress--1.0.sql" | psql "${CONN12[@]}" -X -q

OUT=$(psql "${CONN12[@]}" -X -At -c "SELECT count(*) FROM pg_query_progress" 2>"$WORKDIR/s12.err")
[ "$(grep -c 'must be loaded via shared_preload_libraries' "$WORKDIR/s12.err")" = "1" ]
check "view query warns about missing preload" $?
[ "$OUT" = "0" ]; check "view returns empty set" $? "count=$OUT"

OUT2=$(psql "${CONN12[@]}" -X -At -c "SELECT count(*) FROM pg_query_progress; SELECT count(*) FROM pg_query_progress" 2>&1)
W=$(echo "$OUT2" | grep -c "must be loaded via shared_preload_libraries")
[ "$W" = "1" ]; check "WARNING fires once per session" $? "warnings=$W"

pg_ctl -D "$PGDATA12" stop -m fast > /dev/null 2>&1
rm -rf "$PGDATA12"
finish_scenario
