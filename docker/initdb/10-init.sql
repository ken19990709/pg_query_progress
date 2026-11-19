-- docker/initdb/10-init.sql -- first-boot setup for the trial image.
--
-- The stock docker-entrypoint runs this once, against a throwaway
-- single-user-socket server started with the image CMD, when the data
-- directory is empty; the extension library is already preloaded by
-- then (shared_preload_libraries comes from the image CMD).

CREATE EXTENSION pg_query_progress;

-- Scan-shaped demo fodder: a few million rows, built in seconds, for
-- queries you bring yourself (see the README Docker section).
CREATE TABLE big_table AS
SELECT g AS x,
       (g * 37 % 997) AS y,
       repeat('v', 32) AS pad
FROM generate_series(1, 3000000) AS g;
ANALYZE big_table;

-- Pacing driver for the README demo query: the LATERAL pg_sleep arm
-- emits one row per 40 ms, so `SELECT count(*) FROM pace s, LATERAL
-- (SELECT pg_sleep(0.04), s.k + 1 AS v) sub` takes ~8 s on any hardware
-- and the progress bar has time to animate.
CREATE TABLE pace AS
SELECT g AS k
FROM generate_series(1, 200) AS g;
ANALYZE pace;
