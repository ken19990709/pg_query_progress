# pg_query_progress trial image: PostgreSQL 18 with the extension
# preloaded and a demo schema, so the README quickstart works with a
# single `docker run`.  Published as ghcr.io/ken19990709/pg_query_progress
# by the Docker workflow; build locally with:
#
#   docker build -t pg_query_progress .
#
# ---------------------------------------------------------------------------
# Stage 1 -- build the extension.
#
# The official postgres:18 image (Debian trixie base) ships PostgreSQL 18
# from apt.postgresql.org and already carries the PGDG apt source plus its
# signing key (/usr/local/share/keyrings/postgres.gpg.asc), so the build
# toolchain is one apt-get away.  Server binaries live under
# /usr/lib/postgresql/18/bin (the image puts that on PATH via PG_MAJOR).
# ---------------------------------------------------------------------------
FROM postgres:18 AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        postgresql-server-dev-18 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Makefile pg_query_progress.c pg_query_progress.h pgqp_compat.h \
     pg_query_progress.control pg_query_progress--1.0.sql ./

# PGXS install layout for the pg_config above:
#   pg_query_progress.so                  -> /usr/lib/postgresql/18/lib
#   pg_query_progress.control + --1.0.sql -> /usr/share/postgresql/18/extension
# DESTDIR stages both trees under /stage without touching the base image.
RUN make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config \
    && make install DESTDIR=/stage \
       PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config

# ---------------------------------------------------------------------------
# Stage 2 -- clean runtime: the stock server, the three installed files,
# and the first-boot init script (run by the stock docker-entrypoint).
# ---------------------------------------------------------------------------
FROM postgres:18

COPY --from=builder /stage/usr/lib/postgresql/18/lib/pg_query_progress.so \
     /usr/lib/postgresql/18/lib/pg_query_progress.so
COPY --from=builder \
     /stage/usr/share/postgresql/18/extension/pg_query_progress.control \
     /stage/usr/share/postgresql/18/extension/pg_query_progress--1.0.sql \
     /usr/share/postgresql/18/extension/

COPY docker/initdb/10-init.sql /docker-entrypoint-initdb.d/10-init.sql

# The library allocates its shared memory at server start, so preload it
# via the command line; 10-init.sql then creates the extension's view and
# the demo tables on first boot.
CMD ["postgres", "-c", "shared_preload_libraries=pg_query_progress"]
