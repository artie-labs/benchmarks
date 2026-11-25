-- Run by cdc_start once the warm-up row has landed in DEBEZIUM_HISTORY (created by setup_debezium.sql).
-- The stream starts empty, so the warm-up row isn't merged. The task is created suspended; bench.sh resumes it.
-- Same shape as DMS_MERGE_TASK in setup_dms.sql: every minute, the latest change per account, deletes applied.
-- Variables: dbz_wh.
CREATE OR REPLACE STREAM DEBEZIUM_HISTORY_STREAM ON TABLE DEBEZIUM_HISTORY APPEND_ONLY = TRUE;

CREATE OR REPLACE TASK DEBEZIUM_MERGE_TASK
  WAREHOUSE = <% dbz_wh %>
  SCHEDULE = '1 minute'
WHEN
  SYSTEM$STREAM_HAS_DATA('DEBEZIUM_HISTORY_STREAM')
AS
  MERGE INTO DEBEZIUM_REPLICATION AS t
  USING (
    SELECT * FROM DEBEZIUM_HISTORY_STREAM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY AID ORDER BY __LSN DESC) = 1
  ) AS s
    ON t.AID = s.AID
  WHEN MATCHED AND s.__OP = 'd' THEN DELETE
  WHEN MATCHED THEN
    UPDATE SET
      t.BID = s.BID,
      t.ABALANCE = s.ABALANCE,
      t.FILLER = s.FILLER,
      t.__OP = s.__OP,
      t.__LSN = s.__LSN,
      t.__SOURCE_TS_MS = s.__SOURCE_TS_MS
  WHEN NOT MATCHED AND s.__OP <> 'd' THEN
    INSERT (AID, BID, ABALANCE, FILLER, __OP, __LSN, __SOURCE_TS_MS)
    VALUES (s.AID, s.BID, s.ABALANCE, s.FILLER, s.__OP, s.__LSN, s.__SOURCE_TS_MS);
