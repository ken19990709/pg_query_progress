# Contributing to pg_query_progress

Thanks for your interest in improving pg_query_progress. This document
covers what you need to get a change built, tested, and reviewed.
Usage questions usually do not need a code change -- they fit better in
[GitHub Discussions](https://github.com/ken19990709/pg_query_progress/discussions).

## Environment

- A PostgreSQL installation with development headers for the major you
  target (15 through the 20 development line): either an installed
  server or a source build tree. Its `pg_config` must be reachable, on
  `PATH` or via `PG_CONFIG`.
- A C compiler and `make` (the build is standard PGXS).
- bash, python3, and standard unix utilities for the test suite.

## Building

Point `PG_CONFIG` at the major you are targeting and build:

    make PG_CONFIG=/path/to/pg_config
    make PG_CONFIG=/path/to/pg_config install

See README.md ("Install") for preload setup and for the development
shortcut of preloading the uninstalled shared object by absolute path.

## Running the tests

The suite is self-bootstrapping: it builds the extension, starts a
throwaway instance in a temporary directory on a dynamically allocated
unix socket, and drives real sessions against it. Nothing is installed
into a running cluster.

Run the default matrix for the branch you are on:

    tests/smoke.sh

Run selected scenarios or groups:

    tests/smoke.sh s18          # one scenario
    tests/smoke.sh S R          # the bar-gate and robustness groups

`tests/bootstrap.sh` wraps a single interactive run: it builds, starts
the instance, and prints how to connect; `tests/bootstrap.sh --down`
stops the instance and removes the workdir. Tear down with `--down`
when you are done. See tests/README.md for the full scenario list,
group layout, and environment knobs.

## Branch model and backport discipline

One branch per PostgreSQL major: `main` tracks the 20 development line;
`PG18`, `PG17`, `PG16`, and `PG15` are the stable backport branches.

Six core files are kept byte-identical across all five branches:

- pg_query_progress.c
- pg_query_progress.h
- pgqp_compat.h
- pg_query_progress--1.0.sql
- pg_query_progress.control
- Makefile

All version differences live inside `pgqp_compat.h`; do not add version
conditionals to the other five files. This is what lets a fix apply
cleanly everywhere.

The flow for a fix: land it on `main` first, then cherry-pick the same
commit to each affected stable branch. Only the tests differ across
branches (s26 is main-only, s27 is stable-branches-only). A PR that
changes any of the six core files should say how byte-identity is kept
and where the cherry-picks are going.

## Pull requests

- Keep PRs small and focused: one logical change, with test evidence in
  the description (which scenario scripts you ran, against which major).
- New behavior needs a scenario in tests/scenarios/, or a convincing
  argument for why it cannot be tested there.
- Run `bash tools/audit_leak_check.sh` before submitting; it must
  report 0 hits.
- If README.md is affected (new GUCs, new limitations, changed build or
  test steps), update it in the same PR.

## Code style

Follow the PostgreSQL C coding conventions
(https://www.postgresql.org/docs/devel/source.html). Match the style of
the surrounding code; the sources deliberately read like PostgreSQL
core, and staying close to it keeps diffs reviewable.

## Conduct

Be decent to each other. This project follows the PostgreSQL Code of
Conduct: https://www.postgresql.org/about/policies/coc/
