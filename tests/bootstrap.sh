#!/usr/bin/env bash
# tests/bootstrap.sh -- build the extension and boot a throwaway instance.
#
# Usage:
#   tests/bootstrap.sh [--down]
#
# Behavior:
#   - builds the extension via PGXS against ${PG_CONFIG:-pg_config}
#   - initdb's a temporary cluster under $(mktemp -d), on a dynamically
#     allocated TCP port and a unix socket inside the data directory
#   - preloads the freshly built shared object by ABSOLUTE PATH (no
#     'make install' needed; the instance is throwaway)
#   - installs the view by the sed path documented in
#     pg_query_progress--1.0.sql and loads tests/setup.sql at scale
#     ${PGQP_SCALE:-0.1}
#   - writes the connection environment to tests/.pgqp_env.sh for
#     tests/common.sh; scenario scripts pick it up via PGQP_ENV
#
#   tests/bootstrap.sh --down stops the instance and deletes the cluster.
#
# Environment:
#   PG_CONFIG      pg_config to build against (default: pg_config on PATH)
#   PGQP_SCALE     setup.sql scale (default 0.1; 1.0 = full sizes)
#   PGQP_TOLERANCE timing tolerance multiplier handed to the scenarios
#   PGQP_INCLUDE   server include dir override for the s18 size probe
#                  (default: $(pg_config --includedir-server))

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRCROOT="$(cd "$TESTS_DIR/.." && pwd)"
ENV_FILE="$TESTS_DIR/.pgqp_env.sh"
STATE_DIR="$TESTS_DIR/.bootstrap"

PG_CONFIG="${PG_CONFIG:-pg_config}"
PGQP_SCALE="${PGQP_SCALE:-0.1}"

if ! command -v "$PG_CONFIG" > /dev/null 2>&1; then
  for c in "$PG_CONFIG" "$(pwd)/$PG_CONFIG"; do
    [ -x "$c" ] && PG_CONFIG="$c" && break
  done
fi
command -v "$PG_CONFIG" > /dev/null 2>&1 || {
  echo "bootstrap: pg_config not found ($PG_CONFIG)" >&2
  exit 2
}

PG_BINDIR="$("$PG_CONFIG" --bindir)"
PG_SO="$SRCROOT/pg_query_progress.so"

if [ "${1:-}" = "--down" ]; then
  if [ -f "$STATE_DIR/postmaster.pid" ]; then
    "$PG_BINDIR/pg_ctl" -D "$STATE_DIR/pgdata" stop -m immediate > /dev/null 2>&1
  fi
  rm -rf "$STATE_DIR" "$ENV_FILE"
  echo "bootstrap: instance down, workdir removed"
  exit 0
fi

echo "bootstrap: building against $("$PG_CONFIG" --version) ($PG_CONFIG)"
make -C "$SRCROOT" PG_CONFIG="$PG_CONFIG" -s > /dev/null || {
  echo "bootstrap: build failed" >&2
  exit 2
}
[ -f "$PG_SO" ] || {
  echo "bootstrap: $PG_SO not built" >&2
  exit 2
}

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
PGDATA="$STATE_DIR/pgdata"

PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

"$PG_BINDIR/initdb" -D "$PGDATA" --no-sync --auth=trust > "$STATE_DIR/initdb.log" 2>&1 || {
  echo "bootstrap: initdb failed (see $STATE_DIR/initdb.log)" >&2
  exit 2
}

cat >> "$PGDATA/postgresql.auto.conf" <<EOF
shared_preload_libraries = '$PG_SO'
listen_addresses = ''
unix_socket_directories = '$PGDATA'
EOF

"$PG_BINDIR/pg_ctl" -D "$PGDATA" \
  -o "-p $PORT" \
  -l "$PGDATA/server.log" start -w -t 60 > /dev/null 2>&1 || {
  echo "bootstrap: server failed to start (see $PGDATA/server.log)" >&2
  exit 2
}

CONN=(-h "$PGDATA" -p "$PORT" -U postgres -d postgres)

sed "s|MODULE_PATHNAME|$PG_SO|g" "$SRCROOT/pg_query_progress--1.0.sql" \
  | "${CONN[@]}" psql -X -q 2> "$STATE_DIR/install.log" || {
  echo "bootstrap: view install failed" >&2
  exit 2
}

"${CONN[@]}" psql -X -q -v ON_ERROR_STOP=1 -v scale="$PGQP_SCALE" \
  -f "$TESTS_DIR/setup.sql" > /dev/null 2>&1 || {
  echo "bootstrap: setup.sql failed" >&2
  exit 2
}

cat > "$ENV_FILE" <<EOF
PGHOST="$PGDATA"
PGPORT="$PORT"
PGUSER="postgres"
PGDATABASE="postgres"
PGQP_SO="$PG_SO"
PGQP_BINDIR="$PG_BINDIR"
PG_CONFIG_PGQP="$PG_CONFIG"
PGDATA="$PGDATA"
PGQP_SRCROOT="$SRCROOT"
PGQP_SCALE="$PGQP_SCALE"
PGQP_INCLUDE="${PGQP_INCLUDE:-$("$PG_CONFIG" --includedir-server)}"
EOF

echo "bootstrap: instance up (port $PORT, socket $PGDATA)"
echo "bootstrap: env written to $ENV_FILE (export PGQP_ENV=$ENV_FILE)"
echo "bootstrap: teardown with: $0 --down"
