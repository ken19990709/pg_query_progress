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
    tests/smoke.sh S D R P M L  # the full stable-branch matrix

Groups:

| Group | Scenarios | What they pin down |
|---|---|---|
| S | s13, s21 | bar frame gate: first frame in [gate, gate+0.5s], short-query silence, one terminal frame for checkpoint-starved shapes |
| D | s29-s37 | DML progress: INSERT...VALUES (exact denominator), INSERT...SELECT over a table scan (plus the pinned planner fact that DML sources never grow a Gather), ON CONFLICT attempted-row semantics, UPDATE/DELETE forms incl. the zero-match tick-starvation completion, MERGE node accounting, partition routing + BEFORE-trigger skip/rewrite, cancel/raise/EXPLAIN ANALYZE/DO-block-DML stress, bar_ansi default bytes |
| R | s01, s02, s04, s05, s07, s12, s28 | cancel/error -> failed + slot reuse, cursor CLOSE -> terminated, SRFs tracked, auto_explain coexistence, non-preload warning, pg_stat_statements shmem co-load (both orders) |
| P | s22 (+ s26 on the main branch) | parallel visibility: monotonic progress, no mid-run collapse of completed_cost/tuples_processed, worker counters merged |
| M | s18 | the two shared-memory blocks in pg_shmem_allocations with the exact expected byte counts |
| L | s27 (stable branches only) | parallel_leader_participation=off: D-hat = W arithmetic and the worker-merge path end to end |
| I | s26 (main branch only) | worker-side index scan instrumentation pairing on parallel index/index-only/bitmap plans |
| X | s03, s06, s08, s10, s14, s15, s19, s23 | prepared statements, LIMIT, parallel flag, slot capacity, interval throttling, suppression, bar-off regression, operator matrix |

The MERGE RETURNING arm of s34 runs only where the syntax exists
(server_version_num >= 170000); on older majors it is reported as SKIP.
s36's auto_explain arm skips when no auto_explain shared library is
found (see PGQP_AUTO_EXPLAIN_SO below).

Knobs (environment):

- `PG_CONFIG` -- which pg_config to build/run against (default: PATH)
- `PGQP_SCALE` -- data scale, default 0.1 (set 1.0 for full-size runs)
- `PGQP_TOLERANCE` -- timeout multiplier for slow machines (default 1)
- `PGQP_AUTO_EXPLAIN_SO` -- path to auto_explain.so (s07 skips if absent)
- `PGQP_INCLUDE` -- server include dir for the s18 layout probe
- `PGQP_S14_REPEATS` -- override s14's UNION ALL repetition (default:
  calibrated at runtime to a ~10s arm via one timed probe, so the frame
  spacing assertions hold on -O0 debug and -O2 release kernels alike)
- `PGQP_S26_ROWS`, `PGQP_S26_BHSMULT` -- s26 table size and bitmap-arm
  stretch multiplier (defaults 800k at scale 0.1 and x28)
- `PGQP_S30_MULT` -- s30 source row multiplier (default x5)

The timing-density scenarios (s14, s26, s30, s35) size their workloads
so that frame/poll sampling-density assertions pass against both -O0
debug builds and 2-4x faster -O2 release builds of the same kernel;
sizes only stretch the scenarios, never change what they assert.

Teardown is `tests/bootstrap.sh --down` -- it works when called bare
(no environment needs to be sourced) and removes the workdir only after
the postmaster has verifiably exited; if the stop fails, the workdir is
kept and manual cleanup steps are printed.

Scenario output goes to per-run temporary working directories; nothing is
written into the repository (`tests/results/` is gitignored).

## Why some test areas are not here

The repository deliberately ships no destructive scenarios (kill -9 crash
recovery, postmaster restart loops) and no machine-specific overhead
certification runs: those depend on host properties and belong to a
qualitative lab protocol, not a portable smoke suite.  The behavioral
contracts they checked are covered by the non-destructive scenarios
above; the benchmark methodology chapter of the top-level README
describes how overhead was measured.  The bar's ANSI escapes are pinned
down byte-level (s37), which is deterministic and portable; what stays
out is the human-eye rendering check.
