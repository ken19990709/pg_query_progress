# tests/ -- smoke scenarios for pg_query_progress

The scenarios in this directory are self-bootstrapping shell tests.  They
build the extension, start a throwaway PostgreSQL instance in a temporary
directory (dynamically allocated port, unix-socket-only), and drive real
sessions against it.  Nothing is installed into any running cluster, and
no fixed ports or paths are used.

## Prerequisites

- a PostgreSQL installation with development headers (a source build tree
  works: point `PG_CONFIG` at its `src/bin/pg_config/pg_config`)
- build tools for PGXS (compiler, make)
- bash, python3, standard unix utilities
- `initdb`/`pg_ctl` reachable through `pg_config --bindir`

## Running

Run the whole default matrix for this branch:

    tests/smoke.sh

Select groups or individual scenarios:

    tests/smoke.sh S R          # bar frame gate + robustness core
    tests/smoke.sh s18          # one scenario
    tests/smoke.sh S R P M L    # the full stable-branch matrix

Groups:

| Group | Scenarios | What they pin down |
|---|---|---|
| S | s13, s21 | bar frame gate: first frame in [gate, gate+0.5s], short-query silence, one terminal frame for checkpoint-starved shapes |
| R | s01, s02, s04, s05, s07, s12 | cancel/error -> failed + slot reuse, cursor CLOSE -> terminated, SRFs tracked, auto_explain coexistence, non-preload warning |
| P | s22 (+ s26 on the main branch) | parallel visibility: monotonic progress, no mid-run collapse of completed_cost/tuples_processed, worker counters merged |
| M | s18 | the two shared-memory blocks in pg_shmem_allocations with the exact expected byte counts |
| L | s27 (stable branches only) | parallel_leader_participation=off: D-hat = W arithmetic and the worker-merge path end to end |
| I | s26 (main branch only) | worker-side index scan instrumentation pairing on parallel index/index-only/bitmap plans |
| X | s03, s06, s08, s10, s14, s15, s19, s23 | prepared statements, LIMIT, parallel flag, slot capacity, interval throttling, suppression, bar-off regression, operator matrix |

Knobs (environment):

- `PG_CONFIG` -- which pg_config to build/run against (default: PATH)
- `PGQP_SCALE` -- data scale, default 0.1 (set 1.0 for full-size runs)
- `PGQP_TOLERANCE` -- timeout multiplier for slow machines (default 1)
- `PGQP_AUTO_EXPLAIN_SO` -- path to auto_explain.so (s07 skips if absent)
- `PGQP_INCLUDE` -- server include dir for the s18 layout probe

Scenario output goes to per-run temporary working directories; nothing is
written into the repository (`tests/results/` is gitignored).

## Why some test areas are not here

The repository deliberately ships no destructive scenarios (kill -9 crash
recovery, postmaster restart loops), no machine-specific overhead
certification runs, and no visual ANSI-bar inspections: those depend on
host properties or a human eye and belong to a qualitative lab protocol,
not a portable smoke suite.  The behavioral contracts they checked are
covered by the non-destructive scenarios above; the benchmark methodology
chapter of the top-level README describes how overhead was measured.
