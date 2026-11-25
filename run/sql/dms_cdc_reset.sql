-- Resets DMS's Snowflake state before each CDC run. Run only while the DMS CDC task is stopped.
-- Variables: sns.

TRUNCATE TABLE DMS_HISTORY;
CREATE OR REPLACE STREAM DMS_HISTORY_STREAM ON TABLE DMS_HISTORY APPEND_ONLY = TRUE;

-- Seed the DMS merge target with the snapshot, so DMS merges into a 100M-row table as the other tools do.
INSERT OVERWRITE INTO DMS_REPLICATION (AID, BID, ABALANCE, FILLER)
  SELECT AID, BID, ABALANCE, FILLER FROM DMS_FULL_LOAD;

CREATE OR REPLACE PIPE DMS_CDC_PIPE
  AUTO_INGEST = TRUE
  AWS_SNS_TOPIC = '<% sns %>'
  AS
    COPY INTO DMS_HISTORY (AID, BID, ABALANCE, FILLER, OP, DMS_TIMESTAMP, __FILENAME, __ROW_NUMBER, __SCAN_TIME, __LOADED_AT)
      FROM (
        SELECT
          $1:aid::INT,
          $1:bid::INT,
          $1:abalance::INT,
          $1:filler::VARCHAR,
          $1:Op::VARCHAR,
          $1:dms_timestamp::VARCHAR,
          METADATA$FILENAME,
          METADATA$FILE_ROW_NUMBER,
          METADATA$START_SCAN_TIME::TIMESTAMP_NTZ,
          SYSDATE()
        FROM @DMS_CDC_STAGE
      )
    FILE_FORMAT = (TYPE = 'PARQUET')
    PATTERN = '.*public/pgbench_accounts/.*[.]parquet';
