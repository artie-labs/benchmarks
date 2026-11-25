-- What ran on each tool's warehouse during a run: its merges, and its loads for tools that load with COPY.
-- Variables: start, end (ISO 8601 UTC). bench.sh fills in the @fill line with the warehouses of the tools in TOOLS.
SELECT
  WAREHOUSE_NAME,
  QUERY_TYPE,
  EXECUTION_STATUS,
  COUNT(*) AS QUERIES,
  ROUND(SUM(TOTAL_ELAPSED_TIME) / 1000, 1) AS TOTAL_ELAPSED_S,
  ROUND(AVG(TOTAL_ELAPSED_TIME) / 1000, 2) AS AVG_ELAPSED_S,
  ROUND(MAX(TOTAL_ELAPSED_TIME) / 1000, 2) AS MAX_ELAPSED_S,
  ROUND(SUM(QUEUED_OVERLOAD_TIME) / 1000, 1) AS QUEUED_S,
  SUM(ROWS_PRODUCED) AS ROWS_PRODUCED
FROM (
-- @fill: one SELECT * FROM QUERY_HISTORY_BY_WAREHOUSE per warehouse, joined with UNION ALL (bench.sh)
)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
