# Benchmarks

- [BigQuery MERGE partition pruning](bigquery-merge-partition/README.md): bytes scanned and cost of CDC merges with and without a partition filter, and Artie's raw records vs Debezium JSON.
- [Artie vs AWS DMS into Snowflake](dms/README.md): replication latency and snapshot time, with DMS writing through S3 and Snowpipe.
- [Debezium + Kafka Connect into Snowflake](kafka-connect/README.md): the same workload through Debezium, Kafka and the Snowflake connector.
- [Snowflake Openflow into Snowflake](openflow/README.md): the same workload through the Openflow Connector for PostgreSQL.

[`run/README.md`](run/README.md) is the runbook for `run/bench.sh`, which runs the Postgres-to-Snowflake benchmarks for any of the tools above.

The Postgres-to-Snowflake benchmarks share the infrastructure below: an RDS Postgres instance in a VPC with `pgbench_accounts` loaded (100M rows), plus the DMS resources, all from [`aws/dms/tf`](aws/dms/tf).

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

4. (DMS only) Run the following queries in Snowflake. The other tools don't use S3.

   ```
   CREATE STORAGE INTEGRATION benchmark_dms_s3
     TYPE = EXTERNAL_STAGE
     STORAGE_PROVIDER = 'S3'
     STORAGE_AWS_ROLE_ARN = '<snowflake_s3_role_arn output>'
     ENABLED = TRUE
     STORAGE_ALLOWED_LOCATIONS = ('s3://<dms_s3_bucket output>/dms/', 's3://<dms_s3_bucket output>/dms-full-load/');

   DESC INTEGRATION benchmark_dms_s3;
   ```

5. (DMS only) Set `snowflake_iam_user_arn` and `snowflake_storage_external_id` in [terraform.tfvars](aws/dms/tf/terraform.tfvars).
6. (DMS only) Run apply again

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

## Teardown

To tear down all infrastructure:

```bash
terraform -chdir=aws/dms/tf destroy
```
