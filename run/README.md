# Runbook: Postgres-to-Snowflake benchmarks

This reruns the [Artie vs AWS DMS](https://www.artie.com/blogs/artie-vs-aws-dms) benchmark and records the measurements the first run didn't: latency percentiles, catch-up time, row counts, WAL retained per slot, resource usage per tool, and Snowflake credits per tool. It covers AWS DMS, Debezium on Kafka Connect with the Snowflake connector, and Snowflake Openflow, plus any tool added as a plugin (see [Plugin tools](#plugin-tools)).

`TOOLS` in `.env` (or the environment) picks which tools a run includes: `dms`, `debezium`, `openflow`, or a plugin. The default is `TOOLS=debezium`. Each step only starts, waits for, measures and cleans up the tools in `TOOLS`. The November 2026 runs are in `data/runs/`.

[`bench.sh`](bench.sh) drives every step after the infrastructure is up. It is written to be run by a person or a coding agent, one step at a time or all at once.

## Design

| | |
| --- | --- |
| Snapshot | 100M rows. The tools in `TOOLS` run **one after the other**, with `VACUUM FULL` and a cache warm-up before each. `SNAPSHOT_RUNS` runs each (default 3). |
| CDC | The tools in `TOOLS` run **at the same time** from the same pgbench load, each through its own replication slot. `CDC_RUNS` runs (default 3). |
| Load | `custom_tpcb.sql`, 50 clients, 8 threads, 600 s. It runs from a `pgbench` pod in the EKS cluster. |
| Workload scale | `LOAD_SCALE=1` by default: updates hit 100,000 distinct accounts. The published run passed no `-s`, so pgbench used scale 1. `LOAD_SCALE=1000` spreads updates over all 100M rows. |
| Warehouses | The DMS merge task runs on `BENCHMARK_WH_2` (`DMS_WH`), and the Debezium merge task (`DBZ_WH`) and Openflow's merges (`OF_WH`) on `BENCHMARK_WH`. `check` refuses two tools in one run on the same warehouse, so give each tool in a run its own. All are Large with a 60 s auto-suspend. The script's own polling and measurement queries run on `COMPUTE_WH` (`MEASURE_WH`), so they don't add to any tool's cost. |
| Row timestamps | `sf_setup` recreates the schema and sets `ROW_TIMESTAMP_DEFAULT = TRUE` on it before any table exists. Every table created after that, including the ones a tool creates itself, gets `METADATA$ROW_LAST_COMMIT_TIME`, which all latency and snapshot timings use. |
| DMS | `dms.t3.large`, as in `aws/dms/tf`, with S3 → Snowpipe → a merge task every minute. |
| Debezium | Debezium 3.7.1 → Kafka (Strimzi, from [`k8s/`](../k8s/README.md)) → Snowflake connector 4.4.0 (Snowpipe Streaming), all in one Kafka Connect worker on the m8i.2xlarge node. History goes to `DEBEZIUM_HISTORY`, and a merge task every minute builds `DEBEZIUM_REPLICATION`, as for DMS. **Snapshot:** `initial_only` with 10 threads (10 primary-key ranges in parallel), an 8-partition topic and 8 sink tasks, with the worker at 4 CPUs requested and no limit. Unlike DMS and Openflow, every snapshot row goes through Kafka, so the brokers' CPU is recorded with Debezium's. **CDC:** `no_data`, one partition, worker at 1 CPU. |
| Openflow | The Openflow Connector for PostgreSQL in a Snowflake deployment, reaching RDS through an NLB. See [`openflow/README.md`](../openflow/README.md). |
| Fairness | Before each CDC run, the DMS and Debezium merge targets are reseeded from their snapshots, so every tool merges into a 100M-row table. |

## 1. Infrastructure (you)

1. **VPC and subnets.** A VPC in `us-west-2` with private subnets (for RDS, DMS and EKS) and public subnets with a NAT gateway.
2. **EKS.** A cluster in that VPC with:
   - a general node group (2 × m5.large here);
   - an m8i.2xlarge node group labelled `workload=kafka-connect`, for Kafka Connect, pgbench and the snapshot pods;
   - a Kafka node group of 3 × m5.xlarge, labelled and tainted `workload=kafka` (`NoSchedule`);
   - the EBS CSI driver with a `gp3` storage class (the Kafka volumes), metrics-server (for `kubectl top`), and a `kafka` namespace.
3. **Kafka.** Kafka comes from this repo's [`k8s/`](../k8s/README.md):
   ```sh
   cd k8s
   make kafka_secret strimzi_operator kafka
   ```
   Kafka Connect (Debezium and the Snowflake connector) also comes from `k8s/`. Fill in the two connector secrets and create the registry push secret first; see [`k8s/README.md`](../k8s/README.md#deploy):
   ```sh
   make kafka_connector_secrets kafka_connect      # this repo's k8s/, after RDS exists (step 4)
   ```
4. **RDS, DMS and S3.** This takes two applies, with a Snowflake step between them (ACCOUNTADMIN):
   1. Fill in `aws/dms/tf/terraform.tfvars` with the VPC, subnets and DB password, leaving the two Snowflake values `null`. Then run `terraform -chdir=aws/dms/tf apply`.
   2. In Snowflake, `CREATE STORAGE INTEGRATION benchmark_dms_s3 ...` with the `snowflake_s3_role_arn` and `dms_s3_bucket` outputs, as in **Setup (Infrastructure)** in the [top-level README](../README.md). Then run `DESC INTEGRATION benchmark_dms_s3`. If an integration from an earlier run already allows `s3://<bucket>/dms/` and `s3://<bucket>/dms-full-load/` and the bucket and role names haven't changed, reuse it and set `SF_INTEGRATION` in `.env`.
   3. Copy `STORAGE_AWS_IAM_USER_ARN` and `STORAGE_AWS_EXTERNAL_ID` into `terraform.tfvars` as `snowflake_iam_user_arn` and `snowflake_storage_external_id`, and apply again.
5. **Plugin tools.** For a tool in `TOOLS` that isn't built in, set `TOOLS_DIR` to the directory with its `bench_<tool>.sh`, and follow its own setup.
6. **Snowflake access for the run.**
   - `sf_setup` creates the warehouses of the tools in `TOOLS` (`BENCHMARK_WH`, `BENCHMARK_WH_2`) if they don't exist. `COMPUTE_WH` must already exist.
   - The role used by `SNOW_CONNECTION` needs to create and alter schemas, and to create tables, stages, pipes, streams and tasks in the benchmark database. It also needs to use all four warehouses and run `EXECUTE TASK`.
   - A tool that creates its own tables must own them (it does, as their creator). No `ALTER TABLE` is needed for row timestamps.
   - The Snowflake connector's role (`role` in `k8s/secrets/snowflake-credentials.yaml`) needs to create tables and pipes in the schema. `bench.sh` truncates its tables and creates a stream on `DEBEZIUM_HISTORY`, so the `SNOW_CONNECTION` role needs those rights on tables the connector created. The simplest setup is the same role for both.
   - `cost` reads `SNOWFLAKE.ACCOUNT_USAGE`, so the `SNOW_CONNECTION` role needs `IMPORTED PRIVILEGES` on the `SNOWFLAKE` database.
7. **`run/.env`.** Copy [`env.example`](env.example) to `run/.env` and fill it in.

## 2. What an agent needs

- **Tools:** `kubectl`, `aws`, `terraform`, `jq` and the Snowflake CLI (`brew install snowflake-cli`).
- **Kubernetes:** the cluster context, with rights to create pods, secrets and configmaps in `NAMESPACE`, exec into pods in `NAMESPACE` and `kafka`, read `kafka-secret`, create and delete `KafkaConnector`s and patch the `KafkaConnect` in `kafka`, and use `kubectl top` and the service proxy.
- **AWS:** a profile with DMS (create, start, stop and delete tasks), S3 (delete objects in the DMS bucket), CloudWatch (read metrics) and RDS (describe), plus read access to the Terraform state in `aws/dms/tf`.
- **Snowflake:** a `snow` connection named in `SNOW_CONNECTION`, with the role from step 6.
- **Files:** `run/.env`, and whatever a plugin tool in `TOOLS` needs.

Rules for the agent:
- Run the steps in order.
- Stop and report on the first failure instead of working around it.
- Don't edit Terraform, a plugin's files or `.env`.
- Never print secrets.
- **`sf_setup` drops and recreates the whole benchmark schema.** The other destructive actions are limited to the DMS bucket prefixes, the two benchmark DMS tasks, the records in the two Debezium topics, the connectors `bench.sh` creates (label `bench=debezium`), the Openflow connector and its tables in `OF_DB`, inactive replication slots on the benchmark database, and whatever a plugin tool's hooks reset.

To hand it off, start the agent in this repo and paste:

> Follow `run/README.md` section 3. Run `./run/bench.sh check`, then each step in order, and stop on the first failure. When it finishes, summarize `data/runs/<RUN_ID>/snapshot.csv`, `snapshot_cpu.csv` and each `cdc-*/latency_summary.csv`, and flag any warning `bench.sh` logged.

## 3. Steps (agent)

```sh
./run/bench.sh check          # tools, access, Terraform outputs, configs point at the current RDS, Kafka Connect ready
./run/bench.sh pg_pod         # pgbench pod, with its credentials Secret and custom_tpcb.sql ConfigMap
./run/bench.sh pg_init        # pgbench -i at INIT_SCALE (100M rows), publication, table sizes. About 30 to 60 min.
./run/bench.sh sf_setup       # drop and recreate the schema with ROW_TIMESTAMP_DEFAULT; DMS tables, stages, stream, merge task; DEBEZIUM_REPLICATION
./run/bench.sh row_timestamps # for plugin tools that create their own tables: check their rows get commit times
./run/bench.sh snapshots      # SNAPSHOT_RUNS × (vacuum, then each tool's snapshot, for every tool in TOOLS)
./run/bench.sh cdc_smoke      # optional: 100 updates through each pipeline in TOOLS, checked row for row
./run/bench.sh cdc            # CDC_RUNS × (reset, start the tools, sample, pgbench, wait for catch-up, measure)
./run/bench.sh cost           # Snowflake credits per clock hour. Rerun until it stops warning; metering lags up to 3 h.
./run/bench.sh teardown       # stop tasks, pods and connectors, pause pipes, drop slots
```

`./run/bench.sh all` runs `check` through `cdc`. Single runs can be repeated with `snapshot_<tool> N` (`snapshot_dms`, `snapshot_debezium`, `snapshot_openflow`, or a plugin's) and `cdc_run N`. `cdc_stop` stops everything a CDC run or Debezium snapshot started, after an aborted run. If CloudWatch hadn't published the DMS CPU datapoints yet when a DMS snapshot finished, `snapshot_dms_cpu N <start> <end>` pulls them later; the times are in `snapshot.csv`.

### What each Debezium snapshot does

1. Delete any Debezium connectors, drop idle slots, and resize the Kafka Connect worker to snapshot size (this restarts it).
2. Create the 8-partition snapshot topic if needed and empty it. Truncate `DEBEZIUM_FULL_LOAD`.
3. Start the Snowflake connector (8 tasks), then the Debezium source (`initial_only`, new name, slot `debezium_snapshot`). The clock starts with the source.
4. Sample `kubectl top` every 15 s until `DEBEZIUM_FULL_LOAD` has 100M rows, then wait 60 s.
5. Record the time to the last Snowflake commit, Debezium's own finish time from the worker log, and CPU for the worker and the brokers. Then delete the connectors, drop the slot and empty the topic.

### What each CDC run does

Each part below applies only when its tool is in `TOOLS`.

1. **Reset.**
   - Kubernetes: delete the Debezium connectors, empty the Debezium CDC topic and resize the Kafka Connect worker to CDC size.
   - Plugin tools: their `stop` and `cdc_reset` hooks.
   - DMS and Postgres: delete the DMS CDC task and drop the replication slots.
   - Snowflake: suspend the merge tasks, empty the S3 `dms/` prefix, truncate the history tables, reseed `DMS_REPLICATION` and `DEBEZIUM_REPLICATION` from their snapshots, and recreate the DMS stream and CDC pipe.
2. **Start.** Start the DMS CDC task, Debezium (a new source connector and the `snowflake-cdc` sink), the Openflow connector if it isn't running, and each plugin tool, and wait until their slots are active. Send one warm-up update through each. Then create Debezium's stream and merge task (its history table exists now), resume the merge tasks, and wait 30 s.
3. **Sample**, every 15 s: WAL retained per slot, `kubectl top` for pods and nodes, and Kafka consumer lag for the Snowflake connector and any plugin tool's consumer groups.
4. **Load.** Run pgbench in the pod. The pod's clock records the start and end, and the transaction count comes from pgbench's output.
5. **Wait for catch-up.** Each history table must reach the transaction count and hold steady for 3 minutes, and each plugin tool's `caught_up` hook must pass. On the DMS side, Snowpipe must have no pending files. For DMS and Debezium, the stream must be empty and no merge can be running. The timeout is `CATCHUP_TIMEOUT` (3 h).
6. **Measure.** Latency, both merge tasks' history, queries per warehouse, CloudWatch metrics and run metadata.

## Plugin tools

A tool that isn't built in is a plugin: a `bench_<tool>.sh` in `TOOLS_DIR`, which `bench.sh` sources when `TOOLS` includes `<tool>`. The shared steps call its `<tool>_<hook>` functions. The plugin can use `bench.sh`'s helpers (`kn`, `sf`, `sf_count`, `psql_pod`, `wait_until`, `kafka_lag`, `record_snapshot` and the rest).

| Hook | Required | Called by | Does |
| --- | --- | --- | --- |
| `<tool>_warehouse` | yes | `check`, `cost`, `warehouse_queries.csv` | Prints the tool's Snowflake warehouse |
| `<tool>_latency_sources` | yes | `cdc_run` | Prints `<tool> history <table>` and `<tool> replication <table>` lines |
| `<tool>_slot_name` | yes | `cdc_run` | Prints its replication slot name |
| `<tool>_hist_table`, `<tool>_hist_count` | yes | `cdc_run` | Its history table, and that table's row count |
| `step_snapshot_<tool> N` | for `snapshots` | `snapshots`, `snapshot_<tool> N` | One snapshot run; record it with `record_snapshot` |
| `<tool>_check`, `<tool>_sf_setup`, `<tool>_row_timestamps` | no | the step of the same name | |
| `<tool>_stop`, `<tool>_cdc_reset`, `<tool>_cdc_start DIR` | no | `cdc_run`, `cdc_stop`, `snapshots`, `teardown` | Stop its pipeline; reset before a run; start it |
| `<tool>_warmup_wait`, `<tool>_caught_up` | no | `cdc_run` | Wait for the warm-up row; extra catch-up condition |
| `<tool>_lag_groups`, `<tool>_metadata` | no | `cdc_run` | Kafka consumer groups to sample; lines for `metadata.txt` |

## 4. Results

Everything lands in `data/runs/<RUN_ID>/`:

| File | Contents |
| --- | --- |
| `pg_tables.csv` | Row counts and on-disk sizes of the pgbench tables |
| `snapshot.csv` | Per run and tool: start, tool-reported finish, rows loaded, last Snowflake commit, seconds. Debezium's finish is when it logged the snapshot as complete. |
| `snapshot-debezium-N.log` | Kafka Connect worker logs from the start of the Debezium snapshot. Plugin tools may write their own `snapshot-<tool>-N.log` |
| `snapshot_cpu.csv` | Per run and tool: samples, average and max CPU in cores. DMS from the instance's CloudWatch `CPUUtilization` × its vCPUs, from start to the last Snowflake commit; `debezium` from `kubectl top` on the Kafka Connect pod; `debezium_kafka` for the three brokers, summed. Plugin tools record their own |
| `snapshot-<tool>-N/` `pods.csv`, `nodes.csv` | `kubectl top` for every pod and node during that snapshot |
| `snapshot-debezium-N/state.env` | Source connector name, start and end |
| `snapshot-debezium-N/cost.csv` | Credits in the snapshot's clock hours, as for `cdc-N/cost.csv` |
| `snapshot-dms-N/cloudwatch.csv` | DMS instance CPU during the full load, at 1-minute resolution |
| `cdc-N/state.env` | Load start and end, transaction count, catch-up time, DMS task ARN, Debezium source connector name |
| `cdc-N/pgbench.log` | pgbench progress every 5 s and its summary |
| `cdc-N/latency_summary.csv` | Per tool and mode: rows, avg, p50, p95, p99, min and max latency, last commit, catch-up seconds |
| `cdc-N/latency_minutes.csv` | The same, per minute, for the latency-over-time charts |
| `cdc-N/row_counts.csv` | History table rows against pgbench transactions. More rows than transactions means duplicate loads. |
| `cdc-N/wal.csv` | WAL retained (`restart_lsn`) and unconfirmed (`confirmed_flush_lsn`) per slot |
| `cdc-N/pods.csv`, `nodes.csv` | CPU and memory of every pod and node, including Kafka and pgbench |
| `cdc-N/kafka_lag.csv` | Lag for the Snowflake connector (`connect-snowflake-cdc`) and each plugin tool's consumer groups |
| `cdc-N/cloudwatch.csv` | DMS instance CPU, CPU credits, memory and swap; DMS task CDC latency and incoming changes; RDS CPU, write IOPS, slot disk usage and oldest slot lag |
| `cdc-N/dms_merge_task.csv`, `debezium_merge_task.csv` | Every merge task run, with its duration |
| `cdc-N/warehouse_queries.csv` | Queries, elapsed and queued time per warehouse and query type |
| `cdc-N/cost.csv` | Credits per clock hour from `ACCOUNT_USAGE`, for every hour the run touched: the tools' warehouses, classic Snowpipe (DMS) and Snowpipe Streaming (the Snowflake Kafka connector, Openflow, and any tool using it), and any compute pools in `OF_POOLS` (Openflow), each marked `settled` or `may change` |
| `cost_hourly.csv` | The same for every hour from the first run's start to the last run's end, for runs that share hours |
| `cdc-N/metadata.txt` | Plugin tools' versions (their `metadata` hook), Kafka version, node types, DMS and RDS classes, pgbench version and arguments, warehouse settings, Kafka Connect size, node and connector plugin versions |

Latency is the difference between the commit time pgbench writes into `filler` (the source clock) and `METADATA$ROW_LAST_COMMIT_TIME` in Snowflake. History tables measure every change. Replication tables measure the last change per account. Only rows whose source time falls inside the run's load window, plus 60 s on each side, are counted, so rows left from earlier runs don't affect the numbers.

## 5. Teardown (you)

After `./run/bench.sh teardown`:

1. `terraform -chdir=aws/dms/tf destroy` (RDS, DMS, S3, SNS, IAM). Empty the bucket first if the destroy fails on it.
2. Drop the storage integration if you won't rerun soon.
3. In the VPC Terraform, set `create_temporary_resources = false` and apply to remove the NAT gateway, or destroy the EKS cluster and VPC.
4. Delete any decrypted secrets a plugin tool needed.

## Known limitations

- **Row timestamps.** [Snowflake's docs](https://docs.snowflake.com/en/user-guide/data-engineering/row-timestamps) say `ROW_TIMESTAMP_DEFAULT` covers tables created after it's set, but not whether that includes tables created by the tools themselves. `row_timestamps` checks this before any measurement.
  - Rows written before a table had row timestamps keep a NULL commit time.
  - Turning `ROW_TIMESTAMP` off on a table permanently deletes its stored commit times.
  - If the check fails, run `SELECT SYSTEM$SET_ROW_TIMESTAMP_ON_ALL_SUPPORTED_TABLES('schema', '<db>.<schema>')` (needs MODIFY on the schema) and rerun `row_timestamps`. Then rerun the snapshots, so the snapshot rows have commit times.
- **Shared nodes.** Kafka has its own 3 × `m5.xlarge`. pgbench, Kafka Connect and any plugin tool's pods share the m8i.2xlarge, so tools that run together in CDC runs share a node. Check the TPS in `pgbench.log` against the published run (about 22,400 transactions/s) and node CPU in `nodes.csv` before comparing runs.
- **Debezium is untested end to end.** In particular:
  - The Snowflake connector 4.4.0 is built against the Connect API 3.9 and hasn't been tested by Snowflake on Connect 4.3. Run `cdc_smoke` first.
  - Two of its settings (`snowflake.compatibility.enable.column.identifier.normalization` and `snowflake.streaming.validate.compatibility.with.classic`) come from docs that were only partly verified. If the columns come out lower-case, or the connector refuses to start, check them first.
  - Debezium's parallel snapshot of a single table is marked incubating.
- **Metering lags.** `ACCOUNT_USAGE` can take up to 3 hours to show an hour, and can leave a recent hour out entirely. `cost` warns until the last run's hours have had 4 hours to settle. Pipe credits are limited to the benchmark schema, but warehouse credits include anything else that ran on the warehouse, including Snowsight worksheets.
- **Debezium's Kafka lag isn't a catch-up condition**, because the Snowflake connector commits Kafka offsets from what Snowflake has acknowledged. Its history table count and merge task are.
- **Hourly metering.** Credits are per clock hour, so `cost` widens each run's window to whole hours. Start each CDC run on the hour and keep the tools' warehouses otherwise idle, and each run's `cost.csv` is its own cost. Runs that share an hour each show that whole hour; use `cost_hourly.csv` for those.
- **Versions.** The Kafka version differs from the published run's. `metadata.txt` records what actually ran.
- **CloudWatch task metrics.** These use the task's resource ID from its ARN. If `cloudwatch.csv` has no `dms_task_` rows, check the dimension in `cdc_cloudwatch`.
- **`all` is untested end to end.** The steps have each been run on their own (November 2026), but not `all` in one go. Run `check`, then step through the first run by hand.
