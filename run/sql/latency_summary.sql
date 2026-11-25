-- End-to-end latency per tool and mode: the commit time pgbench wrote into FILLER (source clock) to the row's commit
-- time in Snowflake. History tables have one row per change. Replication tables have the last change per account.
-- Only rows whose source time falls inside this run's load window (plus 60 s on each side) are counted.
-- Variables: load_start, load_end (ISO 8601 UTC). bench.sh fills in the @fill line.
WITH ev AS (
-- @fill: one SELECT per tool and mode in TOOLS, joined with UNION ALL (bench.sh latency_sources)
),
w AS (
  SELECT TOOL, MODE, DST, DATEDIFF('millisecond', SRC, DST) / 1000 AS LAT
  FROM ev
  WHERE SRC BETWEEN DATEADD('second', -60, '<% load_start %>'::TIMESTAMP_TZ)
                AND DATEADD('second', 60, '<% load_end %>'::TIMESTAMP_TZ)
)
SELECT
  TOOL,
  MODE,
  COUNT(*) AS ROWS_IN_WINDOW,
  ROUND(AVG(LAT), 1) AS AVG_S,
  ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY LAT), 1) AS P50_S,
  ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY LAT), 1) AS P95_S,
  ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY LAT), 1) AS P99_S,
  ROUND(MIN(LAT), 1) AS MIN_S,
  ROUND(MAX(LAT), 1) AS MAX_S,
  TO_CHAR(CONVERT_TIMEZONE('UTC', MAX(DST)), 'YYYY-MM-DD"T"HH24:MI:SS.FF3"Z"') AS LAST_COMMIT_UTC,
  -- How long after pgbench stopped the last change landed.
  ROUND(DATEDIFF('millisecond', '<% load_end %>'::TIMESTAMP_TZ, MAX(DST)) / 1000, 1) AS CATCH_UP_S
FROM w
GROUP BY 1, 2
ORDER BY 1, 2;
