# Benchmarking

<details>

<summary>Setup</summary>

## Setup

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

7. Create the stage and the pipe in Snowflake.

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
         FROM @benchmark_dms_stage
         FILE_FORMAT = (TYPE = 'PARQUET')
         MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
   ```

</details>

<details>

<summary>DMS Backfill (Postgres to S3)</summary>

## DMS Backfill (Postgres to S3)

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

### 4. Cleanup

Delete the task when done:

```bash
aws dms delete-replication-task --replication-task-arn <task-arn>
```

</details>

## Teardown

To tear down all infrastructure:

```bash
terraform -chdir=aws/dms/tf destroy
```
