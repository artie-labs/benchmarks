# Kafka and Kafka Connect on Strimzi

Manifests for a Strimzi-managed Kafka cluster and a Kafka Connect cluster running Debezium (Postgres source) into the
Snowflake connector (sink). They need Strimzi 1.x, which only serves `kafka.strimzi.io/v1`. The Makefile pins chart
1.3.1, which supports Kafka and Connect 4.2.0 to 4.3.2.

| Component | Version | Notes |
| --- | --- | --- |
| Kafka, Kafka Connect | 4.3.1 | |
| Debezium Postgres connector | 3.7.1.Final | Built against Connect 4.3.1. |
| Snowflake connector | 4.4.0 | Built against the Connect API 3.9. Snowflake calls later versions "untested", so smoke-test it on 4.3.1 first. |
| Bouncy Castle FIPS | bc-fips 2.1.2, bcutil-fips 2.1.8, bcpkix-fips 2.1.12 | For the encrypted private key. |

## Placement

- **Kafka brokers and controllers:** a dedicated node group of 3 x m5.xlarge, labelled and tainted `workload=kafka`
  (NoSchedule) in the EKS Terraform. Both node pools tolerate the taint, prefer those nodes, and spread one pod per
  node.
- **Kafka Connect:** only nodes labelled `workload=kafka-connect`. The EKS Terraform puts that label on the
  m8i.2xlarge node group, which other benchmark pods share. The label has no taint.

This is the config the benchmark cluster is deployed from.

## Deploy

1. Fill in `secrets/postgres-credentials.yaml` and `secrets/snowflake-credentials.yaml` from the `.example.yaml`
   files. They're gitignored.
2. Check that the `dockerhub-credentials` docker-registry secret exists in `kafka`. Strimzi pushes the built Connect image to
   Docker Hub with it.
3. Run `make kafka_connector_secrets kafka_connect`. The first apply builds the image, which takes a few minutes.
4. Check the worker is `Ready`: `kubectl -n kafka get kafkaconnect connect`. `run/bench.sh check` also checks that
   both connector plugins are installed.

- `strimzi/kafka_connect_snapshot.yaml` is the worker, sized for the snapshot (4 CPU, 8 GiB). `make kafka_connect`
  applies it.
- `strimzi/kafka_connect_cdc.yaml` holds the connector config: the Debezium source and the Snowflake sink, set up
  for CDC. `make kafka_connect_cdc` starts CDC by hand.
- `run/bench.sh` builds its connectors from `kafka_connect_cdc.yaml` for each run and deletes them afterwards:
  - **CDC:** both connectors as they are, except the source gets a new name each run, so it starts without stored
    offsets.
  - **Snapshot:** the same connectors with overrides: `initial_only` with 10 threads, slot `debezium_snapshot`, topic
    `dbsnap.public.pgbench_accounts`, and an 8-task sink into `DEBEZIUM_FULL_LOAD`.

  It also resizes the worker to 1 CPU and 3 GiB for CDC, and deletes any connector applied by hand before a run,
  since it would hold the `debezium` slot.

## How the pipeline is set up

- **Messages:** plain JSON without schemas, compressed with zstd. With schemas, each message would carry its full
  schema, and the 100M-row snapshot wouldn't fit on the brokers' disks.
- **Source:** `ExtractNewRecordState` flattens each event to the row plus `__op`, `__lsn` and `__source_ts_ms`. A
  delete becomes a row with `__op = d` and `__deleted = true`.
  - CDC: `snapshot.mode: no_data`, slot `debezium`, topic `dbserver1.public.pgbench_accounts` (1 partition).
  - Snapshot: `snapshot.mode: initial_only` with 10 threads, slot `debezium_snapshot`, topic
    `dbsnap.public.pgbench_accounts` (8 partitions).
- **Sink:** the Snowflake connector writes to `DEBEZIUM_HISTORY` (CDC) and `DEBEZIUM_FULL_LOAD` (snapshot), which `bench.sh sf_setup` creates with explicit types (otherwise the connector infers `FILLER` as a timestamp), with one
  column per field (`AID`, `BID`, `ABALANCE`, `FILLER`, `__OP`, ...) and `RECORD_METADATA`. Rows are appended through
  Snowpipe Streaming, which is billed per GB ingested rather than by warehouse time. `DEBEZIUM_MERGE_TASK` merges the
  history table into `DEBEZIUM_REPLICATION` every minute on its own warehouse, as DMS's merge task does.
- **Topics are emptied, not deleted, between runs.** The Snowflake connector skips any offset at or below the last
  one it committed, so a recreated topic, whose offsets restart at 0, would be skipped.
