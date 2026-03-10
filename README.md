# Benchmarks

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
     STORAGE_ALLOWED_LOCATIONS = ('s3://<dms_s3_bucket output>/dms/');

   DESC INTEGRATION benchmark_dms_s3;
   ```

5. Set `snowflake_iam_user_arn` and `snowflake_storage_external_id` in [terraform.tfvars](aws/dms/tf/terraform.tfvars).
6. Run apply again

   ```
   terraform -chdir=aws/dms/tf apply
   ```

   Copy the value of the `dms_target_sns_topic_arn` output.

7. Create the target table.

   ```
   CREATE OR REPLACE TABLE <target table> (
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

8. Create the stage and the pipe in Snowflake.

   ```
   CREATE STAGE benchmark_dms_stage
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

### 1. Create the replication task

```bash
aws dms create-replication-task \
  --replication-task-identifier benchmark-dms-full-load-task \
  --replication-instance-arn "$(terraform -chdir=aws/dms/tf output -raw dms_replication_instance_arn)" \
  --source-endpoint-arn "$(terraform -chdir=aws/dms/tf output -raw dms_source_endpoint_arn)" \
  --target-endpoint-arn "$(terraform -chdir=aws/dms/tf output -raw dms_target_endpoint_arn)" \
  --migration-type full-load \
  --table-mappings file://aws/dms/backfill/dms-table-mappings.json \
  --replication-task-settings file://aws/dms/backfill/dms-task-settings.json
```

Copy the value of `ReplicationTaskArn` from the output.

### 2. Start the task

```bash
aws dms start-replication-task \
  --replication-task-arn <task-arn> \
  --start-replication-task-type start-replication
```

### 3. Monitor progress

```bash
watch -n 5 'aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=benchmark-dms-full-load-task \
  --query "ReplicationTasks[0].{Status:Status,Progress:ReplicationTaskStats.FullLoadProgressPercent,TablesLoaded:ReplicationTaskStats.TablesLoaded,TablesErrored:ReplicationTaskStats.TablesErrored,StartedAt:ReplicationTaskStartDate,StoppedAt:ReplicationTaskStats.StopDate}" \
  --output table'
```

### 4. Results

When the `Status` of the task becomes `stopped`, take the difference between `StartedAt` and `StoppedAt`. This is how long it takes to write the 100m rows to S3.

In Snowflake, run the following query:

```sql
SELECT COUNT(*), CURRENT_TIMESTAMP() FROM <target table>;
```

When the count reaches 100 million, take the difference between the current time and `StartedAt` from the DMS task.

### 5. Cleanup

Delete the task when done:

```bash
aws dms delete-replication-task --replication-task-arn <task-arn>
```

</details>

<details>

<summary>DMS Continous Replication (Postgres -> S3 -> Snowpipe)</summary>

## DMS Continous Replication

### 1. Create the replication task

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

### 2. Start the task

```bash
aws dms start-replication-task \
  --replication-task-arn <task-arn> \
  --start-replication-task-type start-replication
```

### 3. Monitor progress

```bash
watch -n 5 'aws dms describe-replication-tasks \
  --filters Name=replication-task-id,Values=benchmark-dms-continuous-task \
  --query "ReplicationTasks[0].{Status:Status,Progress:ReplicationTaskStats.FullLoadProgressPercent,TablesLoaded:ReplicationTaskStats.TablesLoaded,TablesErrored:ReplicationTaskStats.TablesErrored,StartedAt:ReplicationTaskStartDate,StoppedAt:ReplicationTaskStats.StopDate}" \
  --output table'
```

### 4. Generate Load

In the EC2 instance, generate load with:

```
source credentials
./pgbench-load.sh
```

### 5. Results

In Snowflake, run the following query:

```sql
SELECT AVG(latency_seconds), MAX(latency_seconds), MIN(latency_seconds) FROM
(SELECT
  AID,
  FILLER::TIMESTAMP_TZ           AS pg_commit_time,
  METADATA$ROW_LAST_COMMIT_TIME  AS snowflake_loaded_at,
  DATEDIFF('second', pg_commit_time, snowflake_loaded_at) AS latency_seconds
FROM WILLIAM_TEST.BENCHMARK_DMS.PGBENCH_ACCOUNTS
QUALIFY ROW_NUMBER() OVER (PARTITION BY AID ORDER BY METADATA$ROW_LAST_COMMIT_TIME DESC) = 1);
```

</details>

## Teardown

To tear down all infrastructure:

```bash
terraform -chdir=aws/dms/tf destroy
```
