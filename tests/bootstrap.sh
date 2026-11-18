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

# ---------------------------------------------------------------------------
# Teardown (--down).  Deliberately FIRST and self-contained: it must work
# when called bare -- no environment sourced, no pg_config on PATH, no
# LD_LIBRARY_PATH.  Everything needed (the shimmed bindir, the library
# path, the data directory) is read back from the env file this script
# wrote at bootstrap time.  The workdir is removed only after the
# postmaster is verifiably gone; on failure the workdir is KEPT as
# evidence and manual cleanup steps are printed.
# ---------------------------------------------------------------------------
stop_instance() {              # -> 0 iff no postmaster is left running
  local pgdata="$STATE_DIR/pgdata" rc=1 bmpid
  [ -f "$pgdata/postmaster.pid" ] || return 0
  if [ -x "${PGQP_BINDIR:-}/pg_ctl" ]; then
    "${PGQP_BINDIR}/pg_ctl" -D "$pgdata" stop -m immediate
    rc=$?
  else
    echo "bootstrap: no usable pg_ctl (${PGQP_BINDIR:-unset})" >&2
    rc=127
  fi
  # trust but verify: pg_ctl's word is not enough before we rm -rf
  bmpid=$(head -1 "$pgdata/postmaster.pid" 2>/dev/null)
  if [ -n "$bmpid" ] && kill -0 "$bmpid" 2>/dev/null; then
    echo "bootstrap: postmaster $bmpid still alive after stop" >&2
    return 1
  fi
  [ "$rc" = "0" ]
}

if [ "${1:-}" = "--down" ]; then
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
  if stop_instance; then
    rm -rf "$STATE_DIR" "$ENV_FILE"
    echo "bootstrap: instance down, workdir removed"
    exit 0
  fi
  echo "bootstrap: teardown FAILED -- workdir kept for inspection" >&2
  echo "  data dir: $STATE_DIR/pgdata" >&2
  echo "  manual stop: ${PGQP_BINDIR:-<shim bin>}/pg_ctl -D $STATE_DIR/pgdata stop -m immediate" >&2
  echo "  then remove: rm -rf $STATE_DIR $ENV_FILE" >&2
  exit 1
fi

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
PC_BIN="$(readlink -f "$(command -v "$PG_CONFIG" 2>/dev/null || echo "$PG_CONFIG")")"
if [ ! -x "$PG_BINDIR/initdb" ]; then
  # in-tree pg_config reports paths relative to itself; walk up the
  # standard source-tree layout (src/bin/pg_config -> src/bin -> src)
  d="$(dirname "$PC_BIN")"
  while [ "$d" != "/" ]; do
    if [ -f "$d/initdb" ] && [ -x "$d/initdb" ]; then PG_BINDIR="$d"; break; fi
    if [ -f "$d/initdb/initdb" ] && [ -x "$d/initdb/initdb" ]; then PG_BINDIR="$d/initdb"; break; fi
    d="$(dirname "$d")"
  done
fi
if [ ! -f "$PG_BINDIR/initdb" ] || [ ! -x "$PG_BINDIR/initdb" ]; then
  echo "bootstrap: no initdb next to pg_config ($PG_BINDIR)" >&2
  exit 2
fi
TREE_ROOT=""
if [ ! -f "$PG_BINDIR/postgres" ]; then
  # Uninstalled source tree: the binaries sit in separate build dirs
  # (src/backend/postgres, src/bin/*/).  initdb and pg_ctl expect every
  # helper in their own directory, so shim them together with symlinks
  # (created after the workdir reset below).
  d="$(dirname "$PC_BIN")"
  while [ "$d" != "/" ]; do
    if [ -f "$d/src/backend/postgres" ] && [ -f "$d/src/bin/initdb/initdb" ]; then break; fi
    d="$(dirname "$d")"
  done
  if [ "$d" = "/" ]; then
    echo "bootstrap: postgres binary not found for this pg_config" >&2
    exit 2
  fi
  TREE_ROOT="$d"
fi
PG_SO="$SRCROOT/pg_query_progress.so"


# PGXS location: the pg_config-reported one for installed servers; for
# an uninstalled source tree, the tree's own src/makefiles/pgxs.mk with
# the include dirs pointed at the tree's src/include (the reported
# prefix does not exist there)
PGXS="$("$PG_CONFIG" --pgxs)"
MAKE_ARGS=(PG_CONFIG="$PG_CONFIG")
if [ ! -f "$PGXS" ]; then
  d="$(dirname "$PC_BIN")"
  while [ "$d" != "/" ]; do
    if [ -f "$d/src/makefiles/pgxs.mk" ]; then break; fi
    d="$(dirname "$d")"
  done
  if [ "$d" = "/" ] || [ ! -f "$d/src/include/postgres.h" ]; then
    echo "bootstrap: PGXS not found for this pg_config" >&2
    exit 2
  fi
  MAKE_ARGS+=("PGXS=$d/src/makefiles/pgxs.mk"
              "includedir=$d/src/include"
              "includedir_internal=$d/src/include"
              "includedir_server=$d/src/include")
fi

echo "bootstrap: building against $("$PG_CONFIG" --version) ($PG_CONFIG)"
# force a fresh build: the working tree may hold artifacts from a
# different PostgreSQL major
make -C "$SRCROOT" "${MAKE_ARGS[@]}" -s clean > /dev/null 2>&1 || true
make -C "$SRCROOT" "${MAKE_ARGS[@]}" -s > /dev/null || {
  echo "bootstrap: build failed" >&2
  exit 2
}
[ -f "$PG_SO" ] || {
  echo "bootstrap: $PG_SO not built" >&2
  exit 2
}

# refuse to bulldoze a still-running leftover instance: stopping it via
# the self-contained teardown above is the only safe path
if [ -f "$STATE_DIR/pgdata/postmaster.pid" ] &&
   kill -0 "$(head -1 "$STATE_DIR/pgdata/postmaster.pid")" 2>/dev/null; then
  if ! bash "$0" --down; then
    echo "bootstrap: a previous instance is still running; aborting" >&2
    exit 2
  fi
fi

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
PGDATA="$STATE_DIR/pgdata"

if [ -n "$TREE_ROOT" ]; then
  # initdb and the server locate everything (helpers, catalog files,
  # config templates) relative to their own binary location, so assemble
  # an installed-style layout of hard links into the build tree
  # data-file layout differs per major: PostgreSQL 20 keeps the classic
  # share/postgresql prefix, older majors use share directly -- serve both
  # by placing the payload in share/ and self-linking share/postgresql
  SHIM="$STATE_DIR/bin"
  SHARE="$STATE_DIR/share"
  mkdir -p "$SHIM" "$SHARE"
  for b in "$TREE_ROOT/src/backend/postgres" \
           "$TREE_ROOT/src/bin/initdb/initdb" \
           "$TREE_ROOT/src/bin/pg_ctl/pg_ctl" \
           "$TREE_ROOT/src/bin/psql/psql"; do
    [ -f "$b" ] || continue
    ln -f "$b" "$SHIM/$(basename "$b")" 2>/dev/null || cp "$b" "$SHIM/"
  done
  # catalog payload + every config template the tree provides (the exact
  # template set differs per major; taking them all is version-proof)
  for f in postgres.bki snowball_create.sql information_schema.sql \
           sql_features.txt system_constraints.sql errcodes.txt \
           system_views.sql system_functions.sql; do
    src="$(find "$TREE_ROOT/src" -name "$f" -type f 2>/dev/null | head -1)"
    [ -n "$src" ] && { ln -f "$src" "$SHARE/$f" 2>/dev/null || cp "$src" "$SHARE/"; }
  done
  find "$TREE_ROOT/src" -name "*.sample" -type f 2>/dev/null | while read -r src; do
    ln -f "$src" "$SHARE/$(basename "$src")" 2>/dev/null || cp "$src" "$SHARE/" 2>/dev/null
  done
  # shared libraries and extension metadata initdb may need during
  # post-bootstrap (dict_snowball, plpgsql) or scenarios later (plpgsql,
  # auto_explain): every .so the tree built, plus the control/sql files
  # sitting next to every .control found
  # PostgreSQL 20's initdb looks for the payload under share/postgresql
  # (the pre-18 layout); majors from the newer layout read share/ directly
  ln -sfn . "$SHARE/postgresql"
  PKGLIB="$STATE_DIR/lib"
  mkdir -p "$PKGLIB"
  ln -sfn . "$PKGLIB/postgresql"
  find "$TREE_ROOT/src" "$TREE_ROOT/contrib" -name "*.so" -type f 2>/dev/null | while read -r src; do
    ln -f "$src" "$PKGLIB/$(basename "$src")" 2>/dev/null || cp "$src" "$PKGLIB/" 2>/dev/null
  done
  EXTDIR="$SHARE/extension"
  mkdir -p "$EXTDIR"
  find "$TREE_ROOT/src" "$TREE_ROOT/contrib" -name "*.control" -type f 2>/dev/null |
  while read -r ctl; do
    d="$(dirname "$ctl")"
    for src in "$d"/*.control "$d"/*.sql; do
      [ -f "$src" ] && { ln -f "$src" "$EXTDIR/$(basename "$src")" 2>/dev/null || cp "$src" "$EXTDIR/"; }
    done
  done
  # timezone data: system zoneinfo (what make install would copy) and the
  # server's timezone-set definitions from the source tree
  ln -sfn /usr/share/zoneinfo "$SHARE/timezone"
  mkdir -p "$SHARE/timezonesets"
  for d in "$TREE_ROOT/src/timezone" "$TREE_ROOT/src/timezone/tznames"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f \( -name "[A-Z]*" -o -name "*.sets" \) 2>/dev/null |
    while read -r src; do
      case "$(basename "$src")" in
        Makefile|README*|*.c|*.h|*.o) continue ;;
      esac
      ln -f "$src" "$SHARE/timezonesets/$(basename "$src")" 2>/dev/null ||
        cp "$src" "$SHARE/timezonesets/" 2>/dev/null
    done
  done
  # client-side binaries may link the shared libpq of the tree
  for src in "$TREE_ROOT"/src/interfaces/libpq/libpq.so*; do
    [ -f "$src" ] && { ln -f "$src" "$SHIM/$(basename "$src")" 2>/dev/null || cp "$src" "$SHIM/"; }
  done
  PG_BINDIR="$SHIM"
  # the tree's binaries carry an rpath into the (absent) install prefix;
  # make the shim directory itself the library search location
  export LD_LIBRARY_PATH="$SHIM${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  echo "bootstrap: using shimmed install for source tree: $SHIM"
fi

export PATH="$PG_BINDIR:$PATH"

# if anything fails from here on, take the throwaway instance down again
bootstrap_failed() {
  if [ -f "$STATE_DIR/pgdata/postmaster.pid" ]; then
    "$PG_BINDIR/pg_ctl" -D "$STATE_DIR/pgdata" stop -m immediate > /dev/null 2>&1
  fi
}
trap bootstrap_failed EXIT

PORT="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

"$PG_BINDIR/initdb" -D "$PGDATA" -U postgres --no-sync --auth=trust > "$STATE_DIR/initdb.log" 2>&1 || {
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
  | psql "${CONN[@]}" -X -q 2> "$STATE_DIR/install.log" || {
  echo "bootstrap: view install failed" >&2
  exit 2
}

psql "${CONN[@]}" -X -q -v ON_ERROR_STOP=1 -v scale="$PGQP_SCALE" \
  -f "$TESTS_DIR/setup.sql" > /dev/null 2>&1 || {
  echo "bootstrap: setup.sql failed" >&2
  exit 2
}

cat > "$ENV_FILE" <<EOF
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
export PGHOST="$PGDATA"
export PGPORT="$PORT"
export PGUSER="postgres"
export PGDATABASE="postgres"
export PGQP_SO="$PG_SO"
export PGQP_BINDIR="$PG_BINDIR"
export PG_CONFIG_PGQP="$PG_CONFIG"
export PGDATA="$PGDATA"
export PGQP_SRCROOT="$SRCROOT"
export PGQP_SCALE="$PGQP_SCALE"
export PGQP_INCLUDE="${PGQP_INCLUDE:-$("$PG_CONFIG" --includedir-server)}"
export PGQP_PKGLIB="${PKGLIB:-$("$PG_CONFIG" --pkglibdir)}"
EOF

trap - EXIT
echo "bootstrap: instance up (port $PORT, socket $PGDATA)"
echo "bootstrap: env written to $ENV_FILE (export PGQP_ENV=$ENV_FILE)"
echo "bootstrap: teardown with: $0 --down"
