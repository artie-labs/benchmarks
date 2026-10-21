# Benchmarks

- [BigQuery MERGE partition pruning](bigquery-merge-partition): bytes scanned and cost of CDC merges with and without a partition filter, and Artie's raw records vs Debezium JSON.
- Artie vs AWS DMS replication latency into Snowflake: below.

## Results

In Snowflake, the following queries were ran:

- Latency statistics for history table
  [Artie Latency (bucketed)](data/Artie_latency_history_table_2026_03_23.csv)
  [DMS Latency (bucketed)](data/DMS_latency_history_table_2026_03_23.csv)
  ```sql
  -- aggregated
  SELECT AVG(latency_seconds), MAX(latency_seconds), MIN(latency_seconds) FROM
  (SELECT
    AID,
    FILLER::TIMESTAMP_TZ           AS pg_commit_time,
    METADATA$ROW_LAST_COMMIT_TIME  AS snowflake_loaded_at,
    DATEDIFF('second', pg_commit_time, snowflake_loaded_at) AS latency_seconds
  FROM <history table>
  QUALIFY ROW_NUMBER() OVER (PARTITION BY AID ORDER BY METADATA$ROW_LAST_COMMIT_TIME DESC) = 1);

  -- bucket by minute
  SELECT
    DATE_TRUNC('minute', METADATA$ROW_LAST_COMMIT_TIME) AS snowflake_minute,
    COUNT(*)                                              AS row_count,
    AVG(DATEDIFF('second', FILLER::TIMESTAMP_TZ, METADATA$ROW_LAST_COMMIT_TIME)) AS avg_latency_s,
    MAX(DATEDIFF('second', FILLER::TIMESTAMP_TZ, METADATA$ROW_LAST_COMMIT_TIME)) AS max_latency_s,
    MIN(DATEDIFF('second', FILLER::TIMESTAMP_TZ, METADATA$ROW_LAST_COMMIT_TIME)) AS min_latency_s
  FROM <history table>
  GROUP BY 1
  ORDER BY 1;
  ```

- Latency statistics for target table
  [Artie Latency](data/Artie_latency_replication_table_2026_03_23.csv)
  [DMS Latency](data/DMS_latency_replication_table_2026_03_23.csv)
  ```sql
  -- since last update wins, this aggregates the latency for the last write on all updated rows
  SELECT AVG(latency_seconds), MAX(latency_seconds), MIN(latency_seconds) FROM
  (SELECT
    AID,
    FILLER::TIMESTAMP_TZ           AS pg_commit_time,
    METADATA$ROW_LAST_COMMIT_TIME  AS snowflake_loaded_at,
    DATEDIFF('second', pg_commit_time, snowflake_loaded_at) AS latency_seconds
  FROM <target table>
  WHERE FILLER <> '');
  ```

## Prerequisites

### AWS

- Region Code
- VPC ID
- Subnet IDs
- [Local] [AWS CLI Profile](https://docs.aws.amazon.com/cli/v1/userguide/cli-configure-files.html) with permissions to access the VPC and create resources inside it.

<details>

<summary>Setup (Infrastructure)</summary>

## Setup (Infrastructure)

1. Copy [terraform.tfvars.example](aws/dms/tf/terraform.tfvars.example) to [terraform.tfvars](aws/dms/tf/terraform.tfvars).
2. Fill out the variables with your own configuration. (Keep `snowflake_iam_user_arn` and `snowflake_storage_external_id` as null.)
3. Deploy infrastructure

   ```bash
   terraform -chdir=aws/dms/tf apply
   ```

   Copy the value of the `snowflake_s3_role_arn`and `dms_s3_bucket` outputs.

4. Run the following queries in Snowflake.

   ```
   CREATE STORAGE INTEGRATION benchmark_dms_s3
     TYPE = EXTERNAL_STAGE
     STORAGE_PROVIDER = 'S3'
     STORAGE_AWS_ROLE_ARN = '<snowflake_s3_role_arn output>'
     ENABLED = TRUE
     STORAGE_ALLOWED_LOCATIONS = ('s3://<dms_s3_bucket output>/dms/', 's3://<dms_s3_bucket output>/dms-full-load/');

   DESC INTEGRATION benchmark_dms_s3;
   ```

5. Set `snowflake_iam_user_arn` and `snowflake_storage_external_id` in [terraform.tfvars](aws/dms/tf/terraform.tfvars).
6. Run apply again

   ```
   terraform -chdir=aws/dms/tf apply
   ```

   Copy the value of the `dms_target_sns_topic_arn` output.

</details>

<details>

<summary>Setup (Database)</summary>

## Setup (Database)

1. Stand up an EC2 instance inside the same VPC.

2. Copy the [pgbench](pgbench) folder to it.

3. Fill out [credentials](pgbench/credentials) file.
   - PGHOST - `terraform -chdir=aws/dms/tf output rds_endpoint` without the port suffix.
   - PGPASSWORD - `db_password` in [terraform.tfvars](aws/dms/tf/terraform.tfvars)

4. Run the following commands. You should be able to connect to the RDS instance as shown.
   ```
   > source credentials
   > psql
   psql (18.3 (Debian 18.3-1.pgdg13+1), server 18.1)
   SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off, ALPN: postgresql)
   Type "help" for help.

   postgres=>
   ```

5. Exit with `\q`.

6. Run `./pgbench-init.sh`.

7. The `postgres.public.pgbench_accounts` table should be created with 100 million rows.

</details>

<details>

<summary>DMS Full Load (Postgres -> S3 -> Snowpipe)</summary>

## DMS Full Load

Get the ARN of the SNS topic with:
```bash
terraform -chdir=aws/dms/tf output --raw dms_target_sns_topic_arn
```

### 1. Snowflake Setup

Create the target table in Snowflake.

```sql
CREATE OR REPLACE TABLE <target table> (
  AID INT NOT NULL,
  BID INT,
  ABALANCE INT,
  FILLER VARCHAR,
  __FILENAME VARCHAR,
  __ROW_NUMBER INT,
  __SCAN_TIME TIMESTAMP_NTZ,
  __LOADED_AT TIMESTAMP_NTZ DEFAULT SYSDATE(),
  primary key (AID)
) ROW_TIMESTAMP = TRUE;
```

Create the stage and the pipe in Snowflake.

```sql
CREATE OR REPLACE STAGE benchmark_dms_stage_full_load
  URL = 's3://<dms_s3_bucket output>/dms-full-load/'
  STORAGE_INTEGRATION = benchmark_dms_s3
  FILE_FORMAT = (TYPE = 'PARQUET');

CREATE OR REPLACE PIPE benchmark_dms_pipe_full_load
  AUTO_INGEST = TRUE
  AWS_SNS_TOPIC = '<dms_target_sns_topic_arn output>'
  AS
    COPY INTO <target_table>
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
        FROM @benchmark_dms_stage_full_load
    )
    FILE_FORMAT = (TYPE = 'PARQUET');
```

### 2. Create the replication task

```bash
aws dms create-replication-task \
  --replication-task-identifier benchmark-dms-full-load-task \
  --replication-instance-arn "$(terraform -chdir=aws/dms/tf output -raw dms_replication_instance_arn)" \
  --source-endpoint-arn "$(terraform -chdir=aws/dms/tf output -raw dms_source_endpoint_arn)" \
  --target-endpoint-arn "$(terraform -chdir=aws/dms/tf output -raw dms_target_full_load_endpoint_arn)" \
  --migration-type full-load \
  --table-mappings file://aws/dms/backfill/dms-table-mappings.json \
  --replication-task-settings file://aws/dms/backfill/dms-task-settings.json
```

Copy the value of `ReplicationTaskArn` from the output.

### 3. Start the task

```bash
aws dms start-replication-task \
  --replication-task-arn <task-arn> \
  --start-replication-task-type start-replication
```

### 4. Monitor progress

```bash
watch -n 5 'aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=benchmark-dms-full-load-task \
  --query "ReplicationTasks[0].{Status:Status,Progress:ReplicationTaskStats.FullLoadProgressPercent,TablesLoaded:ReplicationTaskStats.TablesLoaded,TablesErrored:ReplicationTaskStats.TablesErrored,StartedAt:ReplicationTaskStartDate,StoppedAt:ReplicationTaskStats.StopDate}" \
  --output table'
```

### 5. Results

When the `Status` of the task becomes `stopped`, take the difference between `StartedAt` and `StoppedAt`. This is how long it takes to write the 100m rows to S3.

In Snowflake, run the following query:

```sql
SELECT COUNT(*), MAX(METADATA$ROW_LAST_COMMIT_TIME) FROM <target table>;
```

When the count reaches 100 million, take the difference between the last commit time and `StartedAt` from the DMS task.

### 6. Cleanup

Delete the task when done:

```bash
aws dms delete-replication-task --replication-task-arn <task-arn>
```

</details>

<details>

<summary>DMS Continous Replication (Postgres -> S3 -> Snowpipe)</summary>

## DMS Continous Replication

Get the ARN of the SNS topic with:
```bash
terraform -chdir=aws/dms/tf output --raw dms_target_sns_topic_arn
```

### 1. Snowflake Setup

Create the history table in Snowflake.

```sql
CREATE OR REPLACE TABLE <history table> (
  AID INT NOT NULL,
  BID INT,
  ABALANCE INT,
  FILLER VARCHAR,
  OP VARCHAR,
  DMS_TIMESTAMP VARCHAR,
  __FILENAME VARCHAR,
  __ROW_NUMBER INT,
  __SCAN_TIME TIMESTAMP_NTZ,
  __LOADED_AT TIMESTAMP_NTZ DEFAULT SYSDATE(),
primary key (AID)
) ROW_TIMESTAMP = TRUE;
```

Create the stage and the pipe in Snowflake.

```sql
CREATE OR REPLACE STAGE benchmark_dms_stage
  URL = 's3://<dms_s3_bucket output>/dms/'
  STORAGE_INTEGRATION = benchmark_dms_s3
  FILE_FORMAT = (TYPE = 'PARQUET');

CREATE OR REPLACE PIPE benchmark_dms_pipe
  AUTO_INGEST = TRUE
  AWS_SNS_TOPIC = '<dms_target_sns_topic_arn output>'
  AS
    COPY INTO <target_table>
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
        FROM @benchmark_dms_stage
    )
    FILE_FORMAT = (TYPE = 'PARQUET');
```


Create a stream from the history table.

```sql
CREATE STREAM benchmark_dms_history_stream ON TABLE <history table>;
```

Create a task to merge changes from the stream to the target table:

```sql
CREATE TASK benchmark_dms_merge_task
  WAREHOUSE = <warehouse>
  SCHEDULE = '1 minute'
WHEN
  SYSTEM$STREAM_HAS_DATA('benchmark_dms_history_stream')
AS
  MERGE INTO <target table> AS t
  USING (
    SELECT * FROM benchmark_dms_history_stream
    QUALIFY ROW_NUMBER() OVER (PARTITION BY AID ORDER BY FILLER DESC) = 1
  ) AS s
    ON t.AID = s.AID
  WHEN MATCHED AND s.OP = 'D' THEN DELETE
  WHEN MATCHED THEN
    UPDATE SET
      t.BID = s.BID,
      t.ABALANCE = s.ABALANCE,
      t.FILLER = s.FILLER,
      t.__FILENAME = s.__FILENAME,
      t.__ROW_NUMBER = s.__ROW_NUMBER,
      t.__SCAN_TIME = s.__SCAN_TIME,
      t.__LOADED_AT = s.__LOADED_AT
  WHEN NOT MATCHED THEN
    INSERT (AID, BID, ABALANCE, FILLER, __FILENAME, __ROW_NUMBER, __SCAN_TIME, __LOADED_AT)
    VALUES (s.AID, s.BID, s.ABALANCE, s.FILLER, s.__FILENAME, s.__ROW_NUMBER, s.__SCAN_TIME, s.__LOADED_AT);

ALTER TASK benchmark_dms_merge_task RESUME;

```

Monitor task with:

```sql
SELECT *
  FROM TABLE(SNOWFLAKE.INFORMATION_SCHEMA.TASK_HISTORY())
  WHERE NAME = 'BENCHMARK_DMS_MERGE_TASK'
  ORDER BY SCHEDULED_TIME DESC;
```

### 2. Create the replication task

```bash
aws dms create-replication-task \
  --replication-task-identifier benchmark-dms-continuous-task \
  --replication-instance-arn "$(terraform -chdir=aws/dms/tf output -raw dms_replication_instance_arn)" \
  --source-endpoint-arn "$(terraform -chdir=aws/dms/tf output -raw dms_source_endpoint_arn)" \
  --target-endpoint-arn "$(terraform -chdir=aws/dms/tf output -raw dms_target_endpoint_arn)" \
  --migration-type cdc \
  --table-mappings file://aws/dms/streaming/dms-table-mappings.json \
  --replication-task-settings file://aws/dms/streaming/dms-task-settings.json
```

Copy the value of `ReplicationTaskArn` from the output.

### 3. Start the task

```bash
aws dms start-replication-task \
  --replication-task-arn <task-arn> \
  --start-replication-task-type start-replication
```

### 4. Monitor progress

```bash
watch -n 5 'aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=benchmark-dms-continuous-task \
  --query "ReplicationTasks[0].{Status:Status,Progress:ReplicationTaskStats.FullLoadProgressPercent,TablesLoaded:ReplicationTaskStats.TablesLoaded,TablesErrored:ReplicationTaskStats.TablesErrored,StartedAt:ReplicationTaskStartDate,StoppedAt:ReplicationTaskStats.StopDate}" \
  --output table'
```

### 5. Generate Load

In the EC2 instance, generate load with:

```
source credentials
./pgbench-load.sh
```

### 6. Results

Refer to the 'Results' section at the top.

</details>

## Teardown

To tear down all infrastructure:

```bash
terraform -chdir=aws/dms/tf destroy
```
