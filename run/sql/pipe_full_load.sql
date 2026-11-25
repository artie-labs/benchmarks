-- Recreated before every DMS snapshot. DMS reuses file names (LOAD00000001.parquet, ...) across runs, and a pipe
-- skips names it has already loaded, so an old pipe would silently skip the new files.
-- Variables: sns.
TRUNCATE TABLE DMS_FULL_LOAD;

CREATE OR REPLACE PIPE DMS_FULL_LOAD_PIPE
  AUTO_INGEST = TRUE
  AWS_SNS_TOPIC = '<% sns %>'
  AS
    COPY INTO DMS_FULL_LOAD (AID, BID, ABALANCE, FILLER, __FILENAME, __ROW_NUMBER, __SCAN_TIME, __LOADED_AT)
      FROM (
        SELECT
          $1:aid::INT,
          $1:bid::INT,
          $1:abalance::INT,
          $1:filler::VARCHAR,
          METADATA$FILENAME,
          METADATA$FILE_ROW_NUMBER,
          METADATA$START_SCAN_TIME::TIMESTAMP_NTZ,
          SYSDATE()
        FROM @DMS_FULL_LOAD_STAGE
      )
    FILE_FORMAT = (TYPE = 'PARQUET')
    PATTERN = '.*public/pgbench_accounts/.*[.]parquet';
