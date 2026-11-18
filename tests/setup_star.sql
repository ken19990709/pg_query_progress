-- tests/setup_star.sql -- star schema for the parallel-visibility scenarios.
--
-- Run with psql -v sscale=<float> (default 1.0 = full sizes):
--   sscale 1.0 : dim_dates 3,650 / dim_stores 500 / dim_customers 2,000,000
--   sscale 0.1 : default smoke sizes (dates and stores stay; 200k customers)
--
-- The cross-join count query below produces a predictable, long-running
-- parallel plan (every customer matches exactly one date; the store cross
-- multiplies it), which is what the visibility scenarios need:
--
--   SELECT count(*) FROM dim_dates d, dim_customers c, dim_stores
--    WHERE d.cal_date = c.reg_date;

\set S :sscale

CREATE TABLE IF NOT EXISTS dim_dates AS
  SELECT g AS date_id, (DATE '2017-01-01' + g::int)::date AS cal_date
  FROM generate_series(1, 3650) g;

CREATE TABLE IF NOT EXISTS dim_stores AS
  SELECT g AS store_id, 'store' || g AS store_name
  FROM generate_series(1, 500) g;

CREATE TABLE IF NOT EXISTS dim_customers AS
  SELECT g AS customer_id,
         (DATE '2017-01-01' + (g % 2900)::int)::date AS reg_date,
         (g * 37 % 997) AS seg,
         repeat('c', 16) AS pad
  FROM generate_series(1, (2000000 * :S)::bigint) g;

CREATE INDEX IF NOT EXISTS dim_customers_reg_date_idx ON dim_customers (reg_date);

ANALYZE;
