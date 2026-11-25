-- Snapshot duration: from t0 (when the task or pod was started) to the last row committed in Snowflake.
-- Variables: table, t0 (ISO 8601 UTC).
SELECT
  COUNT(*) AS ROWS_LOADED,
  TO_CHAR(CONVERT_TIMEZONE('UTC', MAX(METADATA$ROW_LAST_COMMIT_TIME)), 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') AS LAST_COMMIT_UTC,
  ROUND(DATEDIFF('millisecond', '<% t0 %>'::TIMESTAMP_TZ, MAX(METADATA$ROW_LAST_COMMIT_TIME)) / 1000, 1) AS SECONDS
FROM <% table %>;
