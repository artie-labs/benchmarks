-- Snowflake credits for a run, one row per clock hour, from ACCOUNT_USAGE:
-- - warehouse: the tools' warehouses (Transfer's loads and merges, the DMS and Debezium merge tasks)
-- - pipe: classic Snowpipe (DMS)
-- - snowpipe_streaming: Snowpipe Streaming (the Snowflake Kafka connector, Transfer with streaming: true, and Openflow's
--   journal)
-- - compute pools named in `pools` (Openflow's runtime and its deployment's control pool), under whatever SERVICE_TYPE
--   they're metered as. These aren't tied to a schema, so they're matched by name.
--
-- Metering is hourly, so the window is widened to whole hours: from the hour the run started to the end of the hour
-- it finished in. Start each run on the hour (bench.sh's drivers do) and finish it within the hour, and its hours are
-- its own. Two runs in the same hour both get that hour's full credits.
--
-- ACCOUNT_USAGE lags up to 3 hours. STATUS says whether an hour ended at least 3 hours ago; a missing or "may change"
-- hour means rerun `bench.sh cost` later. Streaming pipes also appear under PIPE with 0 credits, so summing both service
-- types counts each credit once. Needs IMPORTED PRIVILEGES on the SNOWFLAKE database.
--
-- Variables: start, end (ISO 8601 UTC), db, schema, of_db (Openflow's destination database; empty for none), pools
-- (comma-separated compute pool names, OPENFLOW_COMPUTE_SNOWFLAKE for Openflow; empty for none).
-- bench.sh fills in the @fill line with the tools' warehouses.
WITH w AS (
  SELECT
    DATE_TRUNC('hour', '<% start %>'::TIMESTAMP_TZ) AS S,
    DATEADD('hour', 1, DATE_TRUNC('hour', '<% end %>'::TIMESTAMP_TZ)) AS E
)
SELECT
  'warehouse' AS KIND,
  m.WAREHOUSE_NAME AS NAME,
  TO_CHAR(CONVERT_TIMEZONE('UTC', m.START_TIME), 'YYYY-MM-DD"T"HH24:MI"Z"') AS HOUR_UTC,
  m.CREDITS_USED,
  m.CREDITS_USED_COMPUTE,
  m.CREDITS_USED_CLOUD_SERVICES,
  NULL AS BYTES,
  IFF(m.END_TIME <= DATEADD('hour', -3, CURRENT_TIMESTAMP()), 'settled', 'may change') AS STATUS
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY m, w
WHERE m.WAREHOUSE_NAME IN (
-- @fill: the warehouses of the tools in TOOLS, quoted and upper-case (bench.sh)
)
  AND m.START_TIME >= w.S AND m.START_TIME < w.E
UNION ALL
SELECT
  LOWER(m.SERVICE_TYPE),
  COALESCE(m.NAME, '(dropped table)'),
  TO_CHAR(CONVERT_TIMEZONE('UTC', m.START_TIME), 'YYYY-MM-DD"T"HH24:MI"Z"'),
  m.CREDITS_USED,
  m.CREDITS_USED_COMPUTE,
  m.CREDITS_USED_CLOUD_SERVICES,
  m.BYTES,
  IFF(m.END_TIME <= DATEADD('hour', -3, CURRENT_TIMESTAMP()), 'settled', 'may change')
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY m, w
WHERE m.SERVICE_TYPE IN ('PIPE', 'SNOWPIPE_STREAMING')
  AND (
    (m.DATABASE_NAME = UPPER('<% db %>') AND m.SCHEMA_NAME = UPPER('<% schema %>'))
    -- Openflow writes to a database of its own (of_db, empty for the other tools).
    OR (m.DATABASE_NAME = UPPER('<% of_db %>') AND m.SCHEMA_NAME = 'PUBLIC')
    -- A dropped table's pipe loses its name and database. Openflow's snapshot rounds drop the destination table, so
    -- with of_db set these rows are counted too, as '(dropped table)'. Check nothing else dropped tables in those hours.
    OR ('<% of_db %>' <> '' AND m.SERVICE_TYPE = 'SNOWPIPE_STREAMING' AND m.DATABASE_NAME IS NULL)
  )
  AND (m.CREDITS_USED > 0 OR m.BYTES > 0)
  AND m.START_TIME >= w.S AND m.START_TIME < w.E
UNION ALL
SELECT
  LOWER(m.SERVICE_TYPE),
  m.NAME,
  TO_CHAR(CONVERT_TIMEZONE('UTC', m.START_TIME), 'YYYY-MM-DD"T"HH24:MI"Z"'),
  m.CREDITS_USED,
  m.CREDITS_USED_COMPUTE,
  m.CREDITS_USED_CLOUD_SERVICES,
  m.BYTES,
  IFF(m.END_TIME <= DATEADD('hour', -3, CURRENT_TIMESTAMP()), 'settled', 'may change')
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY m, w
WHERE ARRAY_CONTAINS(UPPER(m.NAME)::VARIANT, SPLIT(UPPER(REPLACE('<% pools %>', ' ', '')), ','))
  AND m.SERVICE_TYPE NOT IN ('WAREHOUSE_METERING', 'PIPE', 'SNOWPIPE_STREAMING')
  AND m.START_TIME >= w.S AND m.START_TIME < w.E
ORDER BY 1, 2, 3;
