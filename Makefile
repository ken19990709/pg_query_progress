# pg_query_progress Makefile -- standard PGXS build.
#
# Build and install against the PostgreSQL installation found by pg_config
# on PATH (or point PG_CONFIG at a specific one):
#
#   make
#   make install
#
# For development against an uninstalled build tree, skip the install and
# preload the freshly built shared object by absolute path instead (see
# README.md, Install).

MODULE_big = pg_query_progress
OBJS = \
	$(WIN32RES) \
	pg_query_progress.o

EXTENSION = pg_query_progress
DATA = pg_query_progress--1.0.sql
PGFILEDESC = "pg_query_progress - live per-query progress tracking"

# Smoke tests live in tests/ and bootstrap their own temporary instance;
# there is no pg_regress suite.
NO_INSTALLCHECK = 1

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Performance guard: compile this module at -O2 even when the surrounding
# PostgreSQL was configured with a debug/-O0 build.  The per-tuple wrapper
# runs inside ExecProcNode, and at -O0 its call overhead exceeds the
# module's overhead budget by a large margin.  For default builds this is
# a no-op (CFLAGS already carries -O2; the filter removes nothing and the
# trailing -O2 wins over any same-level duplicate).  ABI-safe: same
# compiler, same headers -- the optimization level changes no ABI surface.
override CFLAGS := $(filter-out -O0 -fno-omit-frame-pointer,$(CFLAGS)) -O2
