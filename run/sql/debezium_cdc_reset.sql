-- Resets Debezium's Snowflake state before each CDC run. Run only while the Debezium connectors are deleted.
-- Seeds the merge target with the Debezium snapshot, so Debezium merges into a 100M-row table as the other tools do.
TRUNCATE TABLE DEBEZIUM_HISTORY;
INSERT OVERWRITE INTO DEBEZIUM_REPLICATION (AID, BID, ABALANCE, FILLER, __OP, __LSN, __SOURCE_TS_MS)
  SELECT AID, BID, ABALANCE, FILLER, __OP, __LSN, __SOURCE_TS_MS FROM DEBEZIUM_FULL_LOAD;
