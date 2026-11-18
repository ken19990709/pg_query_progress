-- tests/setup.sql -- workload tables for the scenario scripts.
--
-- Run with psql -v scale=<float> (default 1.0 = full sizes):
--   scale 1.0 : big_table 8,000,000 rows; t1/t2 200,000 rows; slow_outer 200
--   scale 0.1 : default smoke sizes (800k / 20k / 200)
--
-- big_table drives the seq-scan aggregate arms, t1/t2 the join arm, and
-- slow_outer the rate-controlled NestLoop + LATERAL pg_sleep arm (its row
-- count is fixed: query duration is controlled by pg_sleep, not scale).

\set S :scale

CREATE TABLE IF NOT EXISTS big_table AS
  SELECT g AS x, (g * 37 % 997) AS y, repeat('v', 32) AS pad
  FROM generate_series(1, (8000000 * :S)::bigint) g;

CREATE TABLE IF NOT EXISTS t1 AS
  SELECT g AS id, ((g * 37) % 1000000)::int AS k
  FROM generate_series(1, (200000 * :S)::bigint) g;

CREATE TABLE IF NOT EXISTS t2 AS
  SELECT g AS id, ((g * 53) % 1000000)::int AS k
  FROM generate_series(1, (200000 * :S)::bigint) g;

CREATE INDEX IF NOT EXISTS t1_k_idx ON t1 (k);
CREATE INDEX IF NOT EXISTS t2_k_idx ON t2 (k);

CREATE TABLE IF NOT EXISTS slow_outer AS
  SELECT g AS k FROM generate_series(1, 200) g;

ANALYZE;
