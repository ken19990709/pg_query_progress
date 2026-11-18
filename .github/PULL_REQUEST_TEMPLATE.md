## Summary of changes

<!-- One or two sentences: what does this PR change? -->

## Motivation / background

<!-- Why is the change needed? Link issues or discussions where
     relevant. -->

## Testing evidence

<!-- What you ran and what it printed: which scenario scripts
     (tests/smoke.sh groups or individual sXX scripts from
     tests/scenarios/), against which PostgreSQL major and branch, and
     the outcome. Note anything the suite does not cover and how you
     checked it by hand. -->

## Target branch and backport plan

<!-- Fixes land on main first and are then cherry-picked to the stable
     branches. Which branch does this PR target, and does it need
     backporting to PG18/PG17/PG16/PG15?

     If this PR touches one of the six core files that are kept
     byte-identical across the five branches (pg_query_progress.c,
     pg_query_progress.h, pgqp_compat.h, pg_query_progress--1.0.sql,
     pg_query_progress.control, Makefile): explain how byte-identity is
     preserved. Version-specific code belongs in pgqp_compat.h, not in
     conditionals sprinkled through the other core files. -->

## Documentation

<!-- Does README.md (or tests/README.md) need an update? If yes, include
     it in this PR. -->
