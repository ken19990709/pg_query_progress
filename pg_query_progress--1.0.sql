/* pg_query_progress--1.0.sql
 *
 * Creates the pg_query_progress() set-returning function and the
 * pg_query_progress view.  MODULE_PATHNAME is substituted by
 * CREATE EXTENSION via the control file's module_pathname; for a
 * preloaded-library deployment without CREATE EXTENSION, substitute it
 * manually with the library path:
 *
 *   sed "s|MODULE_PATHNAME|/path/to/pg_query_progress.so|g" \
 *       pg_query_progress--1.0.sql | psql
 */

CREATE FUNCTION pg_query_progress(
    OUT pid                int4,
    OUT query              text,
    OUT state              text,          -- running | completed | failed | terminated
    OUT progress           float8,        -- 0..1, monotonic
    OUT total_cost         float8,
    OUT completed_cost     float8,
    OUT plan_rows          float8,        -- root node row estimate
    OUT rows_returned      int8,          -- root node rows emitted so far
    OUT tuples_processed   int8,          -- all-node cumulative rows emitted
    OUT nodes_total        int4,
    OUT nodes_done         int4,
    OUT parallel           bool,
    OUT query_id           int8,          -- plannedstmt->queryId (may be 0)
    OUT query_start        timestamptz,
    OUT last_update        timestamptz,
    OUT age_ms             float8         -- clock_timestamp() - query_start
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_query_progress_srf'
LANGUAGE C STABLE PARALLEL RESTRICTED;

CREATE VIEW pg_query_progress AS
  SELECT * FROM pg_query_progress();

-- Query text is sensitive: no access for PUBLIC by default.
REVOKE ALL ON FUNCTION pg_query_progress() FROM PUBLIC;
REVOKE ALL ON pg_query_progress FROM PUBLIC;

-- Recommended grant for monitoring roles (opt-in, not enabled by default):
-- GRANT SELECT ON pg_query_progress TO pg_monitor;
