-- The Debezium side: warehouse, the two tables the Snowflake connector writes to, and the merge target.
-- debezium_cdc_start.sql creates the stream and merge task.
-- Variables: dbz_wh.
CREATE WAREHOUSE IF NOT EXISTS <% dbz_wh %>
  WITH WAREHOUSE_SIZE = 'LARGE' WAREHOUSE_TYPE = 'STANDARD' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
-- Every tool's warehouse is Large with a 60 s auto-suspend, so their credits are comparable.
ALTER WAREHOUSE <% dbz_wh %> SET WAREHOUSE_SIZE = 'LARGE' AUTO_SUSPEND = 60;

-- Created here with explicit types rather than by the Snowflake connector. Its messages are JSON without schemas, so
-- it infers each column's type from the first row it sees: it typed FILLER (pgbench's commit time as text, with a
-- +00 offset) as TIMESTAMP_NTZ, dropping the offset, which broke the latency queries. The types match the DMS tables.
-- The connector maps fields to columns by name (aid → AID) and adds RECORD_METADATA's contents.
CREATE TABLE DEBEZIUM_FULL_LOAD (
  AID NUMBER NOT NULL,
  BID NUMBER,
  ABALANCE NUMBER,
  FILLER VARCHAR,
  __OP VARCHAR,
  __LSN NUMBER,
  __SOURCE_TS_MS NUMBER,
  __DELETED VARCHAR,
  RECORD_METADATA VARIANT
) ROW_TIMESTAMP = TRUE;

CREATE TABLE DEBEZIUM_HISTORY (
  AID NUMBER NOT NULL,
  BID NUMBER,
  ABALANCE NUMBER,
  FILLER VARCHAR,
  __OP VARCHAR,
  __LSN NUMBER,
  __SOURCE_TS_MS NUMBER,
  __DELETED VARCHAR,
  RECORD_METADATA VARIANT
) ROW_TIMESTAMP = TRUE;

-- Merge target for DEBEZIUM_MERGE_TASK, reseeded from DEBEZIUM_FULL_LOAD before each CDC run.
CREATE TABLE DEBEZIUM_REPLICATION (
  AID INT NOT NULL,
  BID INT,
  ABALANCE INT,
  FILLER VARCHAR,
  __OP VARCHAR,
  __LSN NUMBER,
  __SOURCE_TS_MS NUMBER
) ROW_TIMESTAMP = TRUE;
