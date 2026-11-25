-- Latency per minute of Snowflake commit time, for the latency-over-time charts. Same rows as latency_summary.sql.
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
  TO_CHAR(CONVERT_TIMEZONE('UTC', DATE_TRUNC('minute', DST)), 'YYYY-MM-DD"T"HH24:MI"Z"') AS MINUTE_UTC,
  COUNT(*) AS ROWS_LANDED,
  ROUND(AVG(LAT), 1) AS AVG_S,
  ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY LAT), 1) AS P50_S,
  ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY LAT), 1) AS P95_S,
  ROUND(MIN(LAT), 1) AS MIN_S,
  ROUND(MAX(LAT), 1) AS MAX_S
FROM w
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
