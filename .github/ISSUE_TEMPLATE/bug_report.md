---
name: Bug report
about: Report incorrect or surprising behavior of the extension
labels: bug
---

**PostgreSQL version and repository branch**

<!-- e.g. PostgreSQL 17.2 on the PG17 branch, or a 20devel build on main -->

**Extension version (tag)**

<!-- e.g. v4.0.0-pg17; if you built from a branch commit, give the
     short commit hash instead -->

**How the extension is loaded**

<!-- shared_preload_libraries value, whether CREATE EXTENSION was run,
     and any other preloaded extensions (e.g. pg_stat_statements) -->

**Query and plan shape (sanitized)**

<!-- The shape of the statement and the query text with table, column
     and literal names sanitized.  Plain EXPLAIN output of the affected
     query helps a lot; see the note under "Actual behavior". -->

**Expected behavior**

**Actual behavior**

<!-- If the report is about progress being inaccurate (non-linear,
     stuck, jumping to 1.0): please attach the EXPLAIN output of the
     query.  Progress is computed from the planner's plan_rows and cost
     estimates, so row-count misestimates translate directly into
     non-linear progress -- the plan output is the fastest way to tell
     a planner misestimate apart from an actual bug. -->

**Server log excerpt (if relevant)**
