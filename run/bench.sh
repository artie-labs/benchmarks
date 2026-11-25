#!/usr/bin/env bash
# Driver for the Postgres-to-Snowflake benchmarks: AWS DMS, Debezium (Kafka Connect + Snowflake connector), Snowflake
# Openflow, and any other tool with a plugin in TOOLS_DIR. TOOLS picks which of them a run includes. See run/README.md
# for the runbook.
#
#   ./run/bench.sh <step> [args]
#
# Steps, in order: check pg_pod pg_init sf_setup row_timestamps snapshots cdc_smoke cdc cost teardown
# `all` runs check through cdc. Each step can be rerun on its own.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The Homebrew cask installs snow in an app bundle that non-login shells may not have on PATH.
[[ -x /Applications/SnowflakeCLI.app/Contents/MacOS/snow ]] && PATH="$PATH:/Applications/SnowflakeCLI.app/Contents/MacOS"
ROOT="$(cd "$HERE/.." && pwd)"
# RUN_ID set in the environment wins over run/.env, so one .env can serve several result directories
# (RUN_ID=<id> ./run/bench.sh cost).
# TOOLS likewise (TOOLS=openflow ./run/bench.sh check).
_RUN_ID_FROM_ENV="${RUN_ID:-}"
_TOOLS_FROM_ENV="${TOOLS:-}"
# shellcheck disable=SC1091
[[ -f "$HERE/.env" ]] && source "$HERE/.env"
[[ -n "$_RUN_ID_FROM_ENV" ]] && RUN_ID="$_RUN_ID_FROM_ENV"
[[ -n "$_TOOLS_FROM_ENV" ]] && TOOLS="$_TOOLS_FROM_ENV"

NAMESPACE="${NAMESPACE:-default}"
export AWS_REGION="${AWS_REGION:-us-west-2}"
[[ -n "${AWS_PROFILE:-}" ]] && export AWS_PROFILE
TF_DIR="$ROOT/aws/dms/tf"
SF_INTEGRATION="${SF_INTEGRATION:-benchmark_dms_s3}"
# Which tools the snapshots and CDC runs include, space-separated: dms, debezium, openflow, or a tool with a plugin.
TOOLS="${TOOLS:-debezium}"
BUILTIN_TOOLS="dms debezium openflow"
# Plugins: a tool that isn't built in is defined by TOOLS_DIR/bench_<tool>.sh, which bench.sh sources. The shared steps
# call its <tool>_<hook> functions where they exist; see "Plugin tools" in run/README.md for the hooks.
TOOLS_DIR="${TOOLS_DIR:-}"
for _t in $TOOLS; do
  [[ " $BUILTIN_TOOLS " == *" $_t "* ]] && continue
  [[ -n "$TOOLS_DIR" && -f "$TOOLS_DIR/bench_$_t.sh" ]] ||
    { echo "unknown tool in TOOLS: $_t (built in: $BUILTIN_TOOLS; others need TOOLS_DIR/bench_$_t.sh)" >&2; exit 1; }
done
DMS_WH="${DMS_WH:-BENCHMARK_WH_2}"
# Debezium's merge task. step_check refuses two tools in one run on the same warehouse.
DBZ_WH="${DBZ_WH:-BENCHMARK_WH}"
# Openflow (openflow/README.md). The connector, runtime and secret live in <SF_DB>.OPENFLOW; the connector writes into
# <OF_DB>.PUBLIC (Destination Schema Strategy SOURCE_SCHEMA), a database of its own, so sf_setup never drops its tables.
OF_WH="${OF_WH:-BENCHMARK_WH}"
OF_DB="${OF_DB:-OPENFLOW_BENCHMARK}"
OF_ROLE="${OF_ROLE:-OPENFLOW_ADMIN}"
OF_CONNECTOR="${OF_CONNECTOR:-$SF_DB.OPENFLOW.BENCHMARK_PG}"
OF_RUNTIME="${OF_RUNTIME:-$SF_DB.OPENFLOW.BENCHMARK_RT}"
OF_SLOT="${OF_SLOT:-openflow}"             # "Replication Slot Name" in openflow/config.json
OF_CONFIG="$ROOT/openflow/config.json"     # downloaded from the connector (openflow/README.md); placeholders as in config.json.example are filled in by of_create
OF_DRIVER="${OF_DRIVER:-}"                 # path to the PostgreSQL JDBC jar named in config.json's assetIds
OF_DEST="$OF_DB.PUBLIC.PGBENCH_ACCOUNTS"
# Compute pools whose credits `cost` adds (comma-separated): Openflow's runtime pool and its deployment's control pool,
# from SHOW COMPUTE POOLS. Empty for the other tools.
OF_POOLS="${OF_POOLS:-}"
MEASURE_WH="${MEASURE_WH:-COMPUTE_WH}"   # runs bench.sh's own queries, so they don't count as any tool's cost
INIT_SCALE="${INIT_SCALE:-1000}"   # 100M rows in pgbench_accounts
LOAD_SCALE="${LOAD_SCALE:-1}"      # :scale for custom_tpcb.sql. 1 = 100,000 distinct accounts, as in the published run
CLIENTS="${CLIENTS:-50}"
THREADS="${THREADS:-8}"
DURATION="${DURATION:-600}"
SNAPSHOT_RUNS="${SNAPSHOT_RUNS:-3}"
CDC_RUNS="${CDC_RUNS:-3}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-15}"
CATCHUP_TIMEOUT="${CATCHUP_TIMEOUT:-10800}"
SNAPSHOT_TIMEOUT="${SNAPSHOT_TIMEOUT:-10800}"
RUN_ID="${RUN_ID:-$(date -u +%Y-%m-%d)}"
RESULTS="$ROOT/data/runs/$RUN_ID"

DMS_FULL_LOAD_TASK=benchmark-dms-full-load-task
DMS_CDC_TASK=benchmark-dms-continuous-task
EXPECTED_ROWS=$((INIT_SCALE * 100000))

# Debezium. The Kafka Connect worker is resized between snapshots and CDC (connect_size). Snapshot sizing: 4 CPUs
# requested, no CPU limit.
DBZ_SNAPSHOT_CPU="${DBZ_SNAPSHOT_CPU:-4}"
DBZ_SNAPSHOT_MEMORY="${DBZ_SNAPSHOT_MEMORY:-8Gi}"
DBZ_SNAPSHOT_HEAP="${DBZ_SNAPSHOT_HEAP:-4g}"          # about half the memory: the Snowflake SDK allocates off-heap
DBZ_SNAPSHOT_THREADS="${DBZ_SNAPSHOT_THREADS:-10}"    # snapshot.max.threads: 10 primary-key ranges in parallel
DBZ_SNAPSHOT_PARTITIONS="${DBZ_SNAPSHOT_PARTITIONS:-8}" # snapshot topic partitions = sink tasks
DBZ_CDC_CPU="${DBZ_CDC_CPU:-1}"
DBZ_CDC_MEMORY="${DBZ_CDC_MEMORY:-3Gi}"
DBZ_CDC_HEAP="${DBZ_CDC_HEAP:-1536m}"
# The connector configs come from k8s/strimzi/kafka_connect_cdc.yaml (its Debezium source and Snowflake sink). CDC runs
# use them as they are, apart from a new source name per run. Snapshots use them with the overrides in
# step_snapshot_debezium. The CDC sink name and topic are read from that file (dbz_cdc_init).
DBZ_CDC_FILE="$ROOT/k8s/strimzi/kafka_connect_cdc.yaml"
DBZ_SNAPSHOT_TOPIC=dbsnap.public.pgbench_accounts
# Sink names stay fixed, so their Kafka offsets and Snowflake channel offsets carry over between runs.
DBZ_SNAPSHOT_SINK=snowflake-snapshot

# ---------------------------------------------------------------------------------------------------------- helpers

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
need() { [[ -n "${!1:-}" ]] || die "set $1 in run/.env"; }

k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
kn() { k -n "$NAMESPACE" "$@"; }
psql_pod() { kn exec pgbench -- psql -v ON_ERROR_STOP=1 -At "$@"; }
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
rds_host() { local e; e="$(tf_out rds_endpoint)"; echo "${e%:*}"; }

# Every Snowflake query from this script runs on MEASURE_WH, so none of it is billed to either tool's warehouse.
sf() { snow sql -c "$SNOW_CONNECTION" --warehouse "$MEASURE_WH" --database "$SF_DB" --schema "$SF_SCHEMA" "$@"; }
sf_json() { sf --format json "$@"; }
# First column of the first row of the last statement.
sf_val() {
  sf_json -q "$1" | jq -r 'if (.[0]|type)=="array" then .[-1] else . end | .[0] | to_entries[0].value'
}
# JSON rows (last statement) to CSV with a header.
to_csv() {
  jq -r 'if (.[0]|type)=="array" then .[-1] else . end
         | if length == 0 then empty
           else (.[0] | keys_unsorted) as $k | ($k | @csv), (.[] | [.[$k[]]] | @csv) end'
}
sf_file_csv() { local f="$1"; shift; sf_json -f "$HERE/sql/$f" "$@" | to_csv; }
sf_count() { sf_val "SELECT COUNT(*) AS N FROM $1"; }

# Runs a SQL file with its `-- @fill` line replaced by generated SQL (for the parts that depend on TOOLS), as CSV.
sf_fill_csv() { # file fill [snow args...]
  local f="$1" fill="$2" tmp rc=0
  shift 2
  tmp="$(mktemp)"
  FILL="$fill" awk 'index($0, "-- @fill") == 1 {print ENVIRON["FILL"]; next} {print}' "$HERE/sql/$f" > "$tmp"
  sf_json -f "$tmp" "$@" | to_csv || rc=$?
  rm -f "$tmp"
  return "$rc"
}

uses() { [[ " $TOOLS " == *" $1 "* ]]; }
tool_count() { local t n=0; for t in $TOOLS; do n=$((n + 1)); done; echo "$n"; }
upper() { tr '[:lower:]' '[:upper:]'; }

# Plugin tools: the tools in TOOLS that aren't built in. Each one's bench_<tool>.sh is sourced here, and plugin <hook>
# runs <tool>_<hook> for each of them that defines it.
plugin_tools() { local t; for t in $TOOLS; do [[ " $BUILTIN_TOOLS " == *" $t "* ]] || echo "$t"; done; }
has_hook() { declare -F "$1_$2" > /dev/null; }
plugin() { # hook [args...]
  local t h="$1"
  shift
  for t in $(plugin_tools); do
    if has_hook "$t" "$h"; then "${t}_$h" "$@"; fi
  done
}
for _t in $(plugin_tools); do
  # shellcheck disable=SC1090
  source "$TOOLS_DIR/bench_$_t.sh"
done

# The warehouses of the tools in TOOLS, upper-case, each once.
tool_warehouses() {
  local t
  for t in $TOOLS; do
    case "$t" in dms) echo "$DMS_WH" ;; debezium) echo "$DBZ_WH" ;; openflow) echo "$OF_WH" ;; *) "${t}_warehouse" ;; esac
  done | upper | awk '!seen[$0]++'
}

# The latency queries' sources: one SELECT per tool and mode (history, replication).
latency_sources() {
  local t parts=() p out=""
  for t in $TOOLS; do
    case "$t" in
      dms) parts+=("dms history DMS_HISTORY" "dms replication DMS_REPLICATION") ;;
      debezium) parts+=("debezium history DEBEZIUM_HISTORY" "debezium replication DEBEZIUM_REPLICATION") ;;
      openflow)
        # History is the connector's journal tables (one row per change, FILLER as PAYLOAD__FILLER), however many
        # it has rotated through; replication is its destination table.
        local j
        for j in $(of_journals); do parts+=("openflow history $j PAYLOAD__FILLER"); done
        parts+=("openflow replication $OF_DEST")
        ;;
      *) while read -r p; do parts+=("$p"); done < <("${t}_latency_sources") ;; # a plugin: "<tool> <mode> <table>" lines
    esac
  done
  for p in "${parts[@]}"; do
    # shellcheck disable=SC2086
    set -- $p
    out+="${out:+$'\n'  UNION ALL$'\n'}  SELECT '$1' AS TOOL, '$2' AS MODE, TRY_TO_TIMESTAMP_TZ(TRIM(${4:-FILLER})) AS SRC, METADATA\$ROW_LAST_COMMIT_TIME AS DST FROM $3"
  done
  echo "$out"
}

# warehouse_queries.sql's sources: the query history of each warehouse in use.
warehouse_history_sources() { # start end
  local w out=""
  while read -r w; do
    out+="${out:+$'\n'  UNION ALL$'\n'}  SELECT * FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_WAREHOUSE(WAREHOUSE_NAME => '$w', END_TIME_RANGE_START => '$1'::TIMESTAMP_LTZ, END_TIME_RANGE_END => '$2'::TIMESTAMP_LTZ, RESULT_LIMIT => 10000))"
  done < <(tool_warehouses)
  echo "$out"
}

wait_until() { # timeout_s description command...
  local timeout="$1" desc="$2" start=$SECONDS
  shift 2
  until "$@"; do
    ((SECONDS - start > timeout)) && die "timed out after ${timeout}s waiting for $desc"
    sleep 15
  done
}

# Runs a script (stdin) inside the pgbench pod, detached, so a dropped kubectl exec doesn't kill a long job.
pod_job() {
  local name="$1"
  kn exec -i pgbench -- sh -c "cat > /tmp/$name.sh"
  kn exec pgbench -- sh -c "rm -f /tmp/$name.exit; nohup sh -c 'sh /tmp/$name.sh > /tmp/$name.log 2>&1; echo \$? > /tmp/$name.exit' > /dev/null 2>&1 &"
  until kn exec pgbench -- test -f "/tmp/$name.exit" 2>/dev/null; do sleep 15; done
  kn exec pgbench -- cat "/tmp/$name.log"
  [[ "$(kn exec pgbench -- cat "/tmp/$name.exit")" == 0 ]] || die "$name failed in the pgbench pod (log above)"
}

kafka_lag() { # consumer group -> total lag, or NA if the exporter doesn't report it yet
  k get --raw "/api/v1/namespaces/kafka/services/kafka-exporter-service:80/proxy/metrics" 2>/dev/null |
    awk -v g="consumergroup=\"$1\"" 'index($0, "kafka_consumergroup_lag{") == 1 && index($0, g) {s += $NF; n++}
                                     END {if (n == 0) print "NA"; else printf "%d\n", s}'
}

kafka_broker() {
  local b
  b="$(k -n kafka get pods -l strimzi.io/cluster=artie-kafka,strimzi.io/broker-role=true -o name | head -1)"
  [[ -n "$b" ]] || die "no Kafka broker pod found"
  echo "${b#pod/}"
}

# Runs a Kafka CLI tool on a broker as the artie user: kafka_admin kafka-topics.sh --describe --topic t
kafka_admin() {
  local tool="$1" pw broker rc=0
  shift
  pw="$(k -n kafka get secret kafka-secret -o jsonpath='{.data.KAFKA_SCRAM_PASSWORD}' | base64 -d)"
  broker="$(kafka_broker)"
  k -n kafka exec -i "$broker" -- sh -c 'cat > /tmp/bench-admin.properties' <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="artie" password="$pw";
EOF
  k -n kafka exec "$broker" -- "/opt/kafka/bin/$tool" --bootstrap-server artie-kafka-kafka-bootstrap:9093 \
    --command-config /tmp/bench-admin.properties "$@" || rc=$?
  k -n kafka exec "$broker" -- rm -f /tmp/bench-admin.properties
  return "$rc"
}

kafka_delete_topic() { kafka_admin kafka-topics.sh --delete --if-exists --topic "$1"; }

kafka_partitions() { # topic -> partition count, 0 if it doesn't exist
  { kafka_admin kafka-topics.sh --describe --topic "$1" 2>/dev/null || true; } | grep -c 'Partition: ' || true
}

kafka_topic_ensure() { # topic partitions
  local have
  kafka_admin kafka-topics.sh --create --if-not-exists --topic "$1" --partitions "$2" --replication-factor 3 > /dev/null
  have="$(kafka_partitions "$1")"
  [[ "$have" == "$2" ]] || die "Kafka topic $1 has $have partitions, not $2. Delete it while no connector uses it, then rerun."
}

# Deletes every record in a topic but keeps the topic, so offsets keep increasing. The Snowflake connector tracks the
# last offset it committed per channel and skips anything at or below it, so a recreated topic (offsets from 0) would
# be silently skipped.
kafka_purge_topic() {
  local topic="$1" n p json="" broker
  n="$(kafka_partitions "$topic")"
  ((n > 0)) || return 0
  for ((p = 0; p < n; p++)); do json+="${json:+,}{\"topic\":\"$topic\",\"partition\":$p,\"offset\":-1}"; done
  broker="$(kafka_broker)"
  echo "{\"version\":1,\"partitions\":[$json]}" | k -n kafka exec -i "$broker" -- sh -c 'cat > /tmp/bench-delete-records.json'
  kafka_admin kafka-delete-records.sh --offset-json-file /tmp/bench-delete-records.json > /dev/null
  k -n kafka exec "$broker" -- rm -f /tmp/bench-delete-records.json
}

# ---- Kafka Connect and Debezium

connect_pod() { k -n kafka get pods -l strimzi.io/name=connect-connect -o name | head -1; }

# Kafka Connect's REST API, from inside the worker pod (Strimzi's network policy only lets the operator reach it).
connect_rest() {
  local p
  p="$(connect_pod)"
  [[ -n "$p" ]] || return 1
  k -n kafka exec "$p" -- curl -sf "http://localhost:8083$1"
}

connect_ready() {
  k -n kafka get kafkaconnect connect -o json |
    jq -e '.status.observedGeneration == .metadata.generation and any(.status.conditions[]?; .type == "Ready" and .status == "True")' > /dev/null &&
    connect_rest / > /dev/null
}

# Resizes the worker (CPU request, memory request and limit, heap) if it isn't already that size. Strimzi restarts it.
connect_size() { # cpu memory heap
  local want="$1/$2/$3" have
  have="$(k -n kafka get kafkaconnect connect -o json | jq -r '"\(.spec.resources.requests.cpu)/\(.spec.resources.requests.memory)/\(.spec.jvmOptions["-Xmx"])"')"
  if [[ "$have" != "$want" ]]; then
    log "resizing Kafka Connect from $have to $want (CPU request/memory/heap). This restarts the worker."
    k -n kafka patch kafkaconnect connect --type merge -p "$(jq -nc --arg c "$1" --arg m "$2" --arg h "$3" \
      '{spec: {resources: {requests: {cpu: $c, memory: $m}, limits: {memory: $m}}, jvmOptions: {"-Xms": $h, "-Xmx": $h}}}')" > /dev/null
  fi
  wait_until 900 "Kafka Connect to be ready" "$0" _connect_ready
}

# One of the connectors in kafka_connect_cdc.yaml as JSON, picked by class. Its metadata is reduced to name, namespace
# and labels (plus bench=debezium, which dbz_delete_connectors relies on), so it can be renamed and reapplied.
dbz_cdc_connector() { # source|sink
  local class json
  case "$1" in
    source) class=io.debezium.connector.postgresql.PostgresConnector ;;
    sink) class=com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector ;;
  esac
  json="$(k create --dry-run=client -o json -f "$DBZ_CDC_FILE" |
    jq -c --arg c "$class" '[(.items // [.])[] | select(.spec.class == $c)] | first // empty')"
  [[ -n "$json" ]] || die "no $class connector in $DBZ_CDC_FILE"
  jq -c '.metadata = {name: .metadata.name, namespace: "kafka", labels: ((.metadata.labels // {}) + {bench: "debezium"})}' <<< "$json"
}

# The CDC sink's name and topic, and its Kafka consumer group, from kafka_connect_cdc.yaml. Read once per process.
dbz_cdc_init() {
  [[ -n "${DBZ_CDC_SINK:-}" ]] && return 0
  local sink
  sink="$(dbz_cdc_connector sink)"
  DBZ_CDC_SINK="$(jq -r .metadata.name <<< "$sink")"
  DBZ_CDC_TOPIC="$(jq -r .spec.config.topics <<< "$sink")"
  DBZ_CDC_GROUP="connect-$DBZ_CDC_SINK" # Kafka Connect's consumer group for a sink connector
  [[ "$DBZ_CDC_TOPIC" != *,* ]] || die "the sink in $DBZ_CDC_FILE must read exactly one topic"
}

# Applies a connector (JSON from dbz_cdc_connector) after a jq edit: dbz_apply "$json" '.metadata.name = $n' --arg n x
dbz_apply() {
  local json="$1" filter="$2"
  shift 2
  jq "$@" "$filter" <<< "$json" | k -n kafka apply -f - > /dev/null
}

# Waits until a connector and all its tasks are RUNNING. Dies with the task's stack trace if one fails.
dbz_wait_running() {
  local name="$1" status state start=$SECONDS
  while :; do
    status="$(connect_rest "/connectors/$name/status" 2>/dev/null || true)"
    [[ -n "$status" ]] || status='{}'
    state="$(jq -r 'if (.tasks | length) == 0 then "STARTING" else ([.connector.state] + [.tasks[].state] | unique | join(",")) end' <<< "$status" 2>/dev/null || true)"
    [[ "$state" == RUNNING ]] && return 0
    if [[ "$state" == *FAILED* ]]; then
      jq -r '.connector.trace // empty, (.tasks[]?.trace // empty)' <<< "$status" | head -30 >&2
      die "connector $name failed (trace above)"
    fi
    ((SECONDS - start > 600)) && die "timed out waiting for connector $name to run (state: ${state:-none})"
    sleep 10
  done
}

# Deletes every connector bench.sh created and waits until Kafka Connect has stopped them, so nothing writes to
# Snowflake after a TRUNCATE and the Debezium slots go idle.
dbz_delete_connectors() {
  k -n kafka delete kafkaconnector -l bench=debezium --ignore-not-found --wait=true > /dev/null
  connect_rest /connectors > /dev/null 2>&1 || return 0 # no Connect worker
  wait_until 300 "Kafka Connect to stop the Debezium connectors" bash -c "[[ \$('$0' _connect_rest /connectors) == '[]' ]]"
  if kn get pod pgbench > /dev/null 2>&1; then
    wait_until 120 "the Debezium replication slots to go idle" bash -c \
      "[[ \$('$0' _pg \"SELECT count(*) FROM pg_replication_slots WHERE slot_name LIKE 'debezium%' AND active\") == 0 ]]"
  fi
}

merge_idle() { # stream task -> true when the stream is empty and no task run is executing
  [[ "$(sf_val "SELECT SYSTEM\$STREAM_HAS_DATA('$1') AS N")" == false ]] &&
    [[ "$(sf_val "SELECT COUNT(*) AS N FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => '$2', SCHEDULED_TIME_RANGE_START => DATEADD('hour', -6, CURRENT_TIMESTAMP()))) WHERE STATE = 'EXECUTING'")" == 0 ]]
}

sf_table_exists() { sf_val "SELECT COUNT(*) AS N FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = UPPER('$SF_SCHEMA') AND TABLE_NAME = '$1'"; }

# Openflow. Every statement runs as OF_ROLE, which owns the connector. of_json prints the last statement's rows.
of_json() { sf_json -q "USE ROLE $OF_ROLE; $1" | jq 'if (.[0] | type) == "array" then .[-1] else . end'; }
of_q() { of_json "$1" > /dev/null; }
of_status() { # connector status, or NONE if it doesn't exist
  of_json "SHOW OPENFLOW CONNECTORS LIKE '${OF_CONNECTOR##*.}' IN SCHEMA ${OF_CONNECTOR%.*}" | jq -r '.[0].status // "NONE"'
}
of_wait_status() { # timeout status...
  local timeout="$1"
  shift
  wait_until "$timeout" "the Openflow connector to be $*" bash -c "s=\$('$0' _of_status); [[ ' $* ' == *\" \$s \"* ]]"
}

# Creates the connector from openflow/config.json and the JDBC driver, committed and STOPPED. A new connector has a live
# version; config.json and the jar go next to each other in it, and config.json names the jar in assetIds.
of_create() {
  local tmp jar
  [[ -f "$OF_CONFIG" ]] || die "missing $OF_CONFIG. Download it from a connector and fill it in (Setup (Connector) in openflow/README.md); config.json.example is the reference."
  jar="$(jq -r '.configuration[].properties["Source Database Driver"].assetIds? // empty | .[0]' "$OF_CONFIG")"
  [[ -f "$OF_DRIVER" && "$(basename "$OF_DRIVER")" == "$jar" ]] || die "set OF_DRIVER to the path of $jar (the PostgreSQL JDBC driver, from Maven Central)"
  tmp="$(mktemp -d)"
  sed -e "s|<openflow_pg_host>|$(tf_out openflow_pg_host)|g" -e "s|<SF_DB>|$SF_DB|g" -e "s|<OF_DB>|$OF_DB|g" "$OF_CONFIG" > "$tmp/config.json"
  of_q "CREATE OPENFLOW CONNECTOR $OF_CONNECTOR IN RUNTIME $OF_RUNTIME FROM DEFINITION OPENFLOW_POSTGRES_CDC DISPLAY_NAME = 'Benchmark Postgres'"
  of_wait_status 600 STOPPED
  of_q "PUT 'file://$tmp/config.json' 'snow://openflow_connector/$OF_CONNECTOR/versions/live/' AUTO_COMPRESS = FALSE OVERWRITE = TRUE"
  of_q "PUT 'file://$OF_DRIVER' 'snow://openflow_connector/$OF_CONNECTOR/versions/live/' AUTO_COMPRESS = FALSE OVERWRITE = TRUE"
  of_q "ALTER OPENFLOW CONNECTOR $OF_CONNECTOR COMMIT"
  rm -rf "$tmp"
  sleep 20 # the commit puts it in UPDATING for about a minute; START is refused until it's STOPPED again
  of_wait_status 600 STOPPED
}

# The connector's journal tables, fully qualified: <TABLE>_JOURNAL_<epoch>_<schema generation>, one per schema version.
of_journals() {
  sf_json -q "SHOW TABLES LIKE 'PGBENCH_ACCOUNTS_JOURNAL_%' IN SCHEMA $OF_DB.PUBLIC" | jq -r --arg s "$OF_DB.PUBLIC" '.[].name | "\($s).\(.)"'
}

# Journal rows committed since $1 (ISO 8601 UTC), across all journal tables: the changes of the current run.
of_hist_count() {
  local j sql=""
  for j in $(of_journals); do
    sql+="${sql:+ UNION ALL }SELECT COUNT_IF(METADATA\$ROW_LAST_COMMIT_TIME >= '$1'::TIMESTAMP_TZ) AS N FROM $j"
  done
  [[ -n "$sql" ]] || { echo 0; return; }
  sf_val "SELECT COALESCE(SUM(N), 0) AS N FROM ($sql)" # COUNT_IF over an empty table is NULL
}

# True once the connector's merge has applied everything in the journals: the destination's last commit is after the
# journals' last commit, and nothing is running on OF_WH.
of_merged() {
  local j sql=""
  for j in $(of_journals); do sql+="${sql:+ UNION ALL }SELECT MAX(METADATA\$ROW_LAST_COMMIT_TIME) AS T FROM $j"; done
  [[ -n "$sql" ]] || return 1
  [[ "$(sf_val "SELECT IFF((SELECT MAX(METADATA\$ROW_LAST_COMMIT_TIME) FROM $OF_DEST) > (SELECT MAX(T) FROM ($sql)), 1, 0) AS OK")" == 1 ]] || return 1
  [[ "$(sf_val "SELECT COUNT(*) AS N FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_WAREHOUSE(WAREHOUSE_NAME => '$OF_WH', RESULT_LIMIT => 100)) WHERE EXECUTION_STATUS IN ('RUNNING', 'QUEUED', 'BLOCKED')")" == 0 ]]
}

of_start() {
  [[ "$(of_status)" == RUNNING ]] && return 0
  of_q "ALTER OPENFLOW CONNECTOR $OF_CONNECTOR START"
  of_wait_status 900 RUNNING
}

# Stops, terminates and drops the connector, then drops its tables in OF_DB.PUBLIC and its slot: the state before a
# snapshot round. Dropping a connector keeps its tables and slot, so they're dropped here.
of_drop() {
  local st t
  st="$(of_status)"
  if [[ "$st" != NONE ]]; then
    if [[ "$st" != STOPPED && "$st" != TERMINATING && "$st" != TERMINATED ]]; then
      of_q "ALTER OPENFLOW CONNECTOR $OF_CONNECTOR STOP"
      of_wait_status 900 STOPPED
    fi
    # TERMINATE drains in-flight data and takes a few minutes; DROP is refused until it's TERMINATED.
    [[ "$(of_status)" == TERMINATED ]] || of_q "ALTER OPENFLOW CONNECTOR $OF_CONNECTOR TERMINATE"
    of_wait_status 1800 TERMINATED
    of_q "DROP OPENFLOW CONNECTOR $OF_CONNECTOR"
  fi
  for t in $(sf_json -q "SHOW TABLES IN SCHEMA $OF_DB.PUBLIC" | jq -r '.[].name'); do
    sf -q "DROP TABLE IF EXISTS $OF_DB.PUBLIC.\"$t\"" > /dev/null
  done
  wait_until 300 "the $OF_SLOT slot to be released" bash -c "[[ \$('$0' _pg \"SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$OF_SLOT' AND active\") == 0 ]]"
  psql_pod -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$OF_SLOT'" > /dev/null
}

dms_task_arn() {
  local arn
  arn="$(aws dms describe-replication-tasks --filters "Name=replication-task-id,Values=$1" \
    --query 'ReplicationTasks[0].ReplicationTaskArn' --output text 2>/dev/null || true)"
  [[ "$arn" == None ]] && arn=""
  echo "$arn"
}
dms_status() { aws dms describe-replication-tasks --filters "Name=replication-task-arn,Values=$1" --query 'ReplicationTasks[0].Status' --output text; }

dms_delete_task() {
  local arn status
  arn="$(dms_task_arn "$1")"
  [[ -z "$arn" ]] && return 0
  status="$(dms_status "$arn")"
  if [[ "$status" == running || "$status" == starting ]]; then
    aws dms stop-replication-task --replication-task-arn "$arn" > /dev/null
    wait_until 1800 "DMS task $1 to stop" bash -c "[[ \$(aws dms describe-replication-tasks --filters Name=replication-task-arn,Values=$arn --query 'ReplicationTasks[0].Status' --output text) == stopped ]]"
  fi
  aws dms delete-replication-task --replication-task-arn "$arn" > /dev/null
  aws dms wait replication-task-deleted --filters "Name=replication-task-arn,Values=$arn" 2>/dev/null || true
}

dms_create_task() { # id migration-type endpoint-output settings-dir -> arn
  local arn
  arn="$(aws dms create-replication-task \
    --replication-task-identifier "$1" \
    --replication-instance-arn "$(tf_out dms_replication_instance_arn)" \
    --source-endpoint-arn "$(tf_out dms_source_endpoint_arn)" \
    --target-endpoint-arn "$(tf_out "$3")" \
    --migration-type "$2" \
    --table-mappings "file://$ROOT/aws/dms/$4/dms-table-mappings.json" \
    --replication-task-settings "file://$ROOT/aws/dms/$4/dms-task-settings.json" \
    --query ReplicationTask.ReplicationTaskArn --output text)"
  aws dms wait replication-task-ready --filters "Name=replication-task-arn,Values=$arn"
  echo "$arn"
}

# Openflow's slot is left alone when openflow is in TOOLS: its connector stays running across CDC runs (a new slot would
# mean a new snapshot), and of_drop drops it.
drop_idle_slots() {
  local keep="''" left
  if uses openflow; then keep="'$OF_SLOT'"; fi
  psql_pod -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE NOT active AND slot_name <> $keep" > /dev/null
  left="$(psql_pod -c "SELECT string_agg(slot_name, ',') FROM pg_replication_slots WHERE slot_name <> $keep")"
  [[ -z "$left" ]] || die "replication slots still active: $left. Stop whatever is using them first (./run/bench.sh cdc_stop stops the CDC pipelines of the tools in TOOLS)."
}

csv_append() { # file header row
  [[ -f "$1" ]] || echo "$2" > "$1"
  echo "$3" >> "$1"
}

# ---------------------------------------------------------------------------------------------------------- steps

step_check() {
  local c
  for c in kubectl aws terraform jq snow; do command -v "$c" > /dev/null || die "$c is not installed"; done
  for c in KUBE_CONTEXT SNOW_CONNECTION SF_DB SF_SCHEMA; do need "$c"; done
  [[ -n "$TOOLS" ]] || die "TOOLS is empty"
  if tool_warehouses | grep -qx "$(echo "$MEASURE_WH" | upper)"; then
    die "MEASURE_WH must differ from the tools' warehouses, or measurement queries count as the tools' cost"
  fi
  [[ "$(tool_warehouses | wc -l | tr -d ' ')" == "$(tool_count)" ]] ||
    die "two tools in TOOLS ($TOOLS) share a warehouse, so their credits can't be told apart. Set DMS_WH, DBZ_WH, OF_WH or the plugin's warehouse."
  plugin check
  tf_out rds_endpoint > /dev/null || die "terraform output rds_endpoint missing. Apply $TF_DIR."
  if uses dms; then
    for c in dms_replication_instance_arn dms_source_endpoint_arn dms_target_endpoint_arn \
      dms_target_full_load_endpoint_arn dms_s3_bucket dms_target_sns_topic_arn; do
      tf_out "$c" > /dev/null || die "terraform output $c missing. Apply $TF_DIR."
    done
  fi
  aws sts get-caller-identity --query Arn --output text > /dev/null
  k get nodes > /dev/null
  if uses debezium; then
    k -n kafka get secret kafka-secret > /dev/null || die "kafka-secret missing in namespace kafka"
  fi
  if uses openflow; then
    tf_out openflow_pg_host > /dev/null || die "terraform output openflow_pg_host missing. Set openflow_public_access and apply $TF_DIR."
    of_json "SHOW OPENFLOW RUNTIMES LIKE '${OF_RUNTIME##*.}' IN SCHEMA ${OF_RUNTIME%.*}" | jq -e '.[0].status == "ACTIVE"' > /dev/null ||
      die "Openflow runtime $OF_RUNTIME isn't ACTIVE. See Setup (Snowflake) in openflow/README.md."
    [[ "$(of_status)" != NONE || -f "$OF_DRIVER" ]] || die "no connector $OF_CONNECTOR and OF_DRIVER isn't set, so one can't be created"
  fi
  if uses debezium; then
    k -n kafka get secret postgres-credentials snowflake-credentials > /dev/null ||
      die "Kafka Connect secrets missing in namespace kafka. Run make kafka_connector_secrets in k8s/."
    k -n kafka get kafkaconnect connect > /dev/null || die "KafkaConnect connect missing. Run make kafka_connect in k8s/."
    connect_ready || die "Kafka Connect isn't ready. Check kubectl -n kafka get kafkaconnect connect."
    connect_rest /connector-plugins | jq -e 'map(.class) | index("io.debezium.connector.postgresql.PostgresConnector") and
      index("com.snowflake.kafka.connector.SnowflakeStreamingSinkConnector")' > /dev/null ||
      die "Kafka Connect is missing the Debezium Postgres or Snowflake streaming connector plugin"
    dbz_cdc_init
    dbz_cdc_connector source > /dev/null
  fi
  sf_val "SELECT CURRENT_VERSION() AS V" > /dev/null
  if uses dms; then
    sf_json -q "DESC INTEGRATION $SF_INTEGRATION" > /dev/null || die "storage integration $SF_INTEGRATION missing"
  fi
  log "check passed for TOOLS=\"$TOOLS\". Results go to $RESULTS"
}

step_pg_pod() {
  local pw="${PGPASSWORD:-}"
  [[ -n "$pw" ]] || pw="$(sed -n 's/^[[:space:]]*db_password[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$TF_DIR/terraform.tfvars")"
  [[ -n "$pw" ]] || die "set PGPASSWORD or db_password in terraform.tfvars"
  kn create secret generic pgbench-credentials \
    --from-literal=PGHOST="$(rds_host)" --from-literal=PGUSER=dbuser --from-literal=PGPASSWORD="$pw" \
    --from-literal=PGDATABASE=postgres --from-literal=PGSSLMODE=require \
    --dry-run=client -o yaml | kn apply -f - > /dev/null
  kn create configmap pgbench-scripts --from-file="$ROOT/pgbench/custom_tpcb.sql" \
    --dry-run=client -o yaml | kn apply -f - > /dev/null
  kn apply -f "$HERE/k8s/pgbench.yaml" > /dev/null
  kn wait --for=condition=Ready pod/pgbench --timeout=5m > /dev/null
  psql_pod -c "SELECT version()"
}

step_pg_init() {
  log "loading pgbench tables at scale $INIT_SCALE ($EXPECTED_ROWS rows). This takes a while."
  pod_job init <<EOF
set -e
pgbench -i -I dtGvp -s $INIT_SCALE
EOF
  [[ "$(psql_pod -c 'SELECT count(*) FROM pgbench_accounts')" == "$EXPECTED_ROWS" ]] || die "pgbench_accounts row count is off"
  [[ "$(psql_pod -c 'SHOW rds.logical_replication')" == on ]] || die "rds.logical_replication is off"
  # pgbench -i drops and recreates the tables, which empties any existing publication.
  psql_pod -c "DROP PUBLICATION IF EXISTS dbz_publication" -c "CREATE PUBLICATION dbz_publication FOR TABLE public.pgbench_accounts" > /dev/null
  drop_idle_slots
  mkdir -p "$RESULTS"
  psql_pod -F, -c "SELECT relname, n_live_tup, pg_total_relation_size(relid) FROM pg_stat_user_tables WHERE relname LIKE 'pgbench%' ORDER BY 1" |
    { echo "table,rows,total_bytes"; cat; } > "$RESULTS/pg_tables.csv"
  log "pgbench tables ready"
}

step_pg_vacuum() {
  log "VACUUM FULL pgbench_accounts and warming the cache"
  pod_job vacuum <<'EOF'
set -e
psql -v ON_ERROR_STOP=1 -c "VACUUM FULL pgbench_accounts" -c "SELECT count(*) FROM pgbench_accounts"
EOF
}

step_sf_setup() {
  log "recreating $SF_DB.$SF_SCHEMA. This drops every table in it."
  if uses debezium; then dbz_delete_connectors; fi # a running sink would recreate its table in the new schema
  sf -f "$HERE/sql/setup.sql" -D "db=$SF_DB" -D "schema=$SF_SCHEMA" > /dev/null
  plugin sf_setup
  if uses dms; then
    sf -f "$HERE/sql/setup_dms.sql" -D "dms_wh=$DMS_WH" -D "bucket=$(tf_out dms_s3_bucket)" -D "integration=$SF_INTEGRATION" > /dev/null
  fi
  if uses debezium; then sf -f "$HERE/sql/setup_debezium.sql" -D "dbz_wh=$DBZ_WH" > /dev/null; fi
  log "schema (ROW_TIMESTAMP_DEFAULT = TRUE) and the objects for $TOOLS created"
}

# Checks that the tables a plugin tool creates itself get row timestamps (its row_timestamps hook), before hours of
# snapshots. Debezium's and Openflow's snapshot steps check their own tables.
step_row_timestamps() {
  local t ran=0
  for t in $(plugin_tools); do
    if has_hook "$t" row_timestamps; then "${t}_row_timestamps"; ran=1; fi
  done
  ((ran)) || log "no tool in TOOLS ($TOOLS) has a row_timestamps check, so it's skipped. Debezium's and Openflow's snapshot steps check their own tables."
}

step_snapshot_dms() {
  local i="$1" arn t0 status stats
  log "DMS snapshot run $i"
  sf -f "$HERE/sql/pipe_full_load.sql" -D "sns=$(tf_out dms_target_sns_topic_arn)" > /dev/null
  aws s3 rm "s3://$(tf_out dms_s3_bucket)/dms-full-load/" --recursive --quiet
  dms_delete_task "$DMS_FULL_LOAD_TASK"
  arn="$(dms_create_task "$DMS_FULL_LOAD_TASK" full-load dms_target_full_load_endpoint_arn backfill)"
  t0="$(now)"
  aws dms start-replication-task --replication-task-arn "$arn" --start-replication-task-type start-replication > /dev/null
  local start=$SECONDS
  while status="$(dms_status "$arn")"; [[ "$status" != stopped && "$status" != failed ]]; do
    ((SECONDS - start > SNAPSHOT_TIMEOUT)) && die "DMS full load timed out"
    sleep 15
  done
  [[ "$status" == stopped ]] || die "DMS full load failed"
  stats="$(aws dms describe-replication-tasks --filters "Name=replication-task-arn,Values=$arn" \
    --query 'ReplicationTasks[0].[ReplicationTaskStats.FullLoadStartDate,ReplicationTaskStats.FullLoadFinishDate,StopReason]' --output text)"
  log "DMS wrote to S3: $stats. Waiting for Snowpipe."
  wait_until "$SNAPSHOT_TIMEOUT" "DMS_FULL_LOAD to reach $EXPECTED_ROWS rows" bash -c "[[ \$('$0' _sf_count DMS_FULL_LOAD) -ge $EXPECTED_ROWS ]]"
  sleep 60 # let late files land so the row count and last commit are final
  record_snapshot dms "$i" "$t0" DMS_FULL_LOAD "$(echo "$stats" | awk '{print $2}')"
  snapshot_dms_cpu "$i" "$t0"
}

# DMS instance CPU over the snapshot, from CloudWatch at 1-minute resolution. Cores = % × the instance's vCPUs.
snapshot_dms_cpu() { # run t0 [end, default now]
  local i="$1" t0="$2" end="${3:-$(now)}" dir inst vcpus
  dir="$RESULTS/snapshot-dms-$i"
  mkdir -p "$dir"
  inst="$(aws dms describe-replication-instances --query 'ReplicationInstances[0].[ReplicationInstanceIdentifier,ReplicationInstanceClass]' --output text \
    --filters "Name=replication-instance-arn,Values=$(tf_out dms_replication_instance_arn)")"
  vcpus="$(aws ec2 describe-instance-types --instance-types "${inst##*dms.}" --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text)"
  echo "metric,timestamp,average,maximum" > "$dir/cloudwatch.csv"
  cloudwatch_csv dms_instance_CPUUtilization AWS/DMS CPUUtilization "$t0" "$end" "$dir/cloudwatch.csv" \
    "Name=ReplicationInstanceIdentifier,Value=${inst%%$'\t'*}" || true
  # CloudWatch can take a few minutes to publish the last datapoints.
  [[ "$(wc -l < "$dir/cloudwatch.csv")" -gt 1 ]] || { log "WARNING: no DMS CPU datapoints yet. Rerun snapshot_dms_cpu $i $t0 $end later."; return 0; }
  record_snapshot_cpu dms "$i" "cloudwatch AWS/DMS CPUUtilization x $vcpus vCPU" "$(tail -n +2 "$dir/cloudwatch.csv" |
    awk -F, -v v="$vcpus" '{a += $3; if ($4 > m) m = $4; n++} END {printf "%d,%.2f,%.2f", n, a / n / 100 * v, m / 100 * v}')"
}

record_snapshot_cpu() { # tool run source "samples,avg_cores,max_cores"
  csv_append "$RESULTS/snapshot_cpu.csv" "tool,run,source,samples,avg_cores,max_cores" "$1,$2,\"$3\",$4"
  log "snapshot $1 run $2 CPU (samples,avg,max cores): $4"
}

record_snapshot() { # tool run t0 table tool_finished
  local row
  row="$(sf_json -f "$HERE/sql/snapshot_measure.sql" -D "table=$4" -D "t0=$3" | jq -r '.[0] | [.ROWS_LOADED, .LAST_COMMIT_UTC, .SECONDS] | @csv')"
  csv_append "$RESULTS/snapshot.csv" "tool,run,started_utc,tool_finished_utc,rows_loaded,last_commit_utc,seconds" "$1,$2,$3,$5,$row"
  log "snapshot $1 run $2: $row"
}

# Debezium snapshot: Debezium (initial_only, DBZ_SNAPSHOT_THREADS threads) → an 8-partition Kafka topic → the Snowflake
# connector (one task per partition) → DEBEZIUM_FULL_LOAD. Unlike DMS and Openflow, every row goes through Kafka, so the
# brokers' CPU is recorded too. Timed like the others: from starting the source connector to the last Snowflake commit.
step_snapshot_debezium() {
  local i="$1" dir="$RESULTS/snapshot-debezium-$1" src t0 n finished
  log "Debezium snapshot run $i"
  mkdir -p "$dir"
  : > "$dir/state.env"
  dbz_delete_connectors
  drop_idle_slots
  connect_size "$DBZ_SNAPSHOT_CPU" "$DBZ_SNAPSHOT_MEMORY" "$DBZ_SNAPSHOT_HEAP"
  kafka_topic_ensure "$DBZ_SNAPSHOT_TOPIC" "$DBZ_SNAPSHOT_PARTITIONS"
  kafka_purge_topic "$DBZ_SNAPSHOT_TOPIC"
  # Start every run from an empty table, as for the other tools. sf_setup creates it (setup_debezium.sql).
  sf -q "TRUNCATE TABLE IF EXISTS DEBEZIUM_FULL_LOAD" > /dev/null
  # The CDC sink from kafka_connect_cdc.yaml, pointed at the snapshot topic and table, one task per partition. Started
  # first, so it's already consuming when the first rows arrive.
  dbz_apply "$(dbz_cdc_connector sink)" '.metadata.name = $n | .spec.tasksMax = $tasks | .spec.config.topics = $topic
    | .spec.config["snowflake.topic2table.map"] = ($topic + ":DEBEZIUM_FULL_LOAD")' \
    --arg n "$DBZ_SNAPSHOT_SINK" --arg topic "$DBZ_SNAPSHOT_TOPIC" --argjson tasks "$DBZ_SNAPSHOT_PARTITIONS"
  dbz_wait_running "$DBZ_SNAPSHOT_SINK"
  src="debezium-snapshot-$(date -u +%Y%m%d%H%M%S)"
  kube_sampler_start "$dir"
  trap 'samplers_stop "'"$dir"'"' EXIT
  t0="$(now)"
  # The CDC source from kafka_connect_cdc.yaml, switched to a one-off parallel snapshot: initial_only (snapshot, then
  # stop), DBZ_SNAPSHOT_THREADS threads splitting the table by primary-key range (incubating in Debezium 3.7), bigger
  # batches, its own slot and topic, and no automatic restart, which would load the table twice.
  dbz_apply "$(dbz_cdc_connector source)" '.metadata.name = $n | .spec.autoRestart.enabled = false
    | .spec.config += {"slot.name": "debezium_snapshot", "topic.prefix": $prefix, "snapshot.mode": "initial_only",
                       "snapshot.max.threads": $threads, "max.batch.size": 10240, "max.queue.size": 40960}' \
    --arg n "$src" --arg prefix "${DBZ_SNAPSHOT_TOPIC%%.*}" --argjson threads "$DBZ_SNAPSHOT_THREADS"
  {
    echo "DBZ_SOURCE=$src"
    echo "SNAPSHOT_START=$t0"
  } >> "$dir/state.env"
  dbz_wait_running "$src"
  wait_until "$SNAPSHOT_TIMEOUT" "DEBEZIUM_FULL_LOAD to reach $EXPECTED_ROWS rows" bash -c "[[ \$('$0' _sf_count DEBEZIUM_FULL_LOAD) -ge $EXPECTED_ROWS ]]"
  sleep 60 # let the last channel flushes land so the row count and last commit are final
  samplers_stop "$dir"
  trap - EXIT
  # When Debezium finished reading the table (it logs this once the last row is queued), from the worker's log.
  k -n kafka logs "$(connect_pod)" --timestamps --since-time="$t0" > "$RESULTS/snapshot-debezium-$i.log" 2>&1 || true
  finished="$(grep -m1 -E 'Snapshot ended with SnapshotResult \[status=COMPLETED|Snapshot completed' "$RESULTS/snapshot-debezium-$i.log" |
    awk '{print substr($1, 1, 19) "Z"}' || true)"
  [[ -n "$finished" ]] || log "WARNING: no snapshot completion line in $RESULTS/snapshot-debezium-$i.log, so tool_finished_utc is empty"
  record_snapshot debezium "$i" "$t0" DEBEZIUM_FULL_LOAD "$finished"
  echo "SNAPSHOT_END=$(now)" >> "$dir/state.env"
  n="$(sf_count DEBEZIUM_FULL_LOAD)"
  ((n == EXPECTED_ROWS)) || log "WARNING: DEBEZIUM_FULL_LOAD has $n rows, expected $EXPECTED_ROWS (a restarted task loads rows twice)"
  [[ "$(sf_val "SELECT COUNT_IF(METADATA\$ROW_LAST_COMMIT_TIME IS NULL) AS N FROM DEBEZIUM_FULL_LOAD")" == 0 ]] ||
    log "WARNING: DEBEZIUM_FULL_LOAD has rows without commit times, so ROW_TIMESTAMP_DEFAULT didn't apply. See Known limitations in run/README.md."
  snapshot_debezium_cpu "$i"
  dbz_delete_connectors
  drop_idle_slots
  kafka_purge_topic "$DBZ_SNAPSHOT_TOPIC" # free the brokers' disk for the next run
}

# Openflow snapshot: a new connector from openflow/config.json reads pgbench_accounts with keyset-paged SELECTs (100,000
# rows at a time, one query at a time) and loads the destination table directly, then switches to CDC on its slot.
# Timed like the others: from START to the last Snowflake commit. Its runtime runs in Snowflake, so there's no CPU to
# sample; the node type is in metadata.
step_snapshot_openflow() {
  local i="$1" dir="$RESULTS/snapshot-openflow-$1" t0 n
  log "Openflow snapshot run $i"
  mkdir -p "$dir"
  : > "$dir/state.env"
  of_drop
  of_create
  t0="$(now)"
  echo "SNAPSHOT_START=$t0" >> "$dir/state.env"
  of_start
  wait_until "$SNAPSHOT_TIMEOUT" "$OF_DEST to reach $EXPECTED_ROWS rows" bash -c "[[ \$('$0' _sf_count $OF_DEST) -ge $EXPECTED_ROWS ]]"
  sleep 60 # let the last commits land so the row count and last commit are final
  record_snapshot openflow "$i" "$t0" "$OF_DEST" ""
  echo "SNAPSHOT_END=$(now)" >> "$dir/state.env"
  n="$(sf_count "$OF_DEST")"
  ((n == EXPECTED_ROWS)) || log "WARNING: $OF_DEST has $n rows, expected $EXPECTED_ROWS"
  [[ "$(sf_val "SELECT COUNT_IF(METADATA\$ROW_LAST_COMMIT_TIME IS NULL) AS N FROM $OF_DEST")" == 0 ]] ||
    log "WARNING: $OF_DEST has rows without commit times, so ROW_TIMESTAMP_DEFAULT didn't apply to $OF_DB.PUBLIC"
  of_metadata > "$dir/metadata.txt"
}

of_metadata() {
  of_json "DESCRIBE OPENFLOW CONNECTOR $OF_CONNECTOR" | jq -r '.[0] | "openflow_connector=\(.connector_definition) version \(.default_version_name)"'
  of_json "SHOW OPENFLOW RUNTIMES LIKE '${OF_RUNTIME##*.}' IN SCHEMA ${OF_RUNTIME%.*}" |
    jq -r '.[0] | "openflow_runtime=\(.name) node_type \(.node_type) nodes \(.min_nodes)-\(.max_nodes) deployment \(.deployment)"'
  echo "of_wh=$OF_WH"
  echo "of_dest=$OF_DEST"
}

# Connect worker CPU (Debezium and the Snowflake connector share it) and the three brokers' CPU summed, from the
# kubectl top samples, in cores.
snapshot_debezium_cpu() { # run
  local i="$1" f="$RESULTS/snapshot-debezium-$1/pods.csv" stats
  stats="$(awk -F, '$2 == "kafka" && $3 ~ /^connect-connect-/ {c = $4; sub(/m$/, "", c); c /= 1000; a += c; if (c > m) m = c; n++}
    END {if (n) printf "%d,%.2f,%.2f", n, a / n, m}' "$f")"
  if [[ -n "$stats" ]]; then
    record_snapshot_cpu debezium "$i" "kubectl top Kafka Connect pod (Debezium and the Snowflake connector) on $(k -n kafka get "$(connect_pod)" -o jsonpath='{.spec.nodeName}' 2>/dev/null)" "$stats"
  else
    log "WARNING: no kubectl top samples for the Kafka Connect pod. Check $f."
  fi
  stats="$(awk -F, '$2 == "kafka" && $3 ~ /^artie-kafka-kafka-[0-9]+$/ {c = $4; sub(/m$/, "", c); s[$1] += c / 1000}
    END {for (t in s) {a += s[t]; if (s[t] > m) m = s[t]; n++} if (n) printf "%d,%.2f,%.2f", n, a / n, m}' "$f")"
  [[ -n "$stats" ]] && record_snapshot_cpu debezium_kafka "$i" "kubectl top, 3 Kafka brokers summed" "$stats"
  return 0
}

step_snapshots() {
  mkdir -p "$RESULTS"
  plugin stop
  if uses debezium; then dbz_delete_connectors; fi
  local i t
  for ((i = 1; i <= SNAPSHOT_RUNS; i++)); do
    for t in $TOOLS; do
      step_pg_vacuum
      "step_snapshot_$t" "$i"
    done
  done
  column -s, -t < "$RESULTS/snapshot.csv" >&2
}

cdc_reset() {
  log "resetting CDC state for $TOOLS"
  cdc_stop_tools
  plugin cdc_reset
  if uses dms; then
    aws s3 rm "s3://$(tf_out dms_s3_bucket)/dms/" --recursive --quiet
    sf -f "$HERE/sql/dms_cdc_reset.sql" -D "sns=$(tf_out dms_target_sns_topic_arn)" > /dev/null
  fi
  if uses openflow; then
    # The connector keeps running between runs, on the same slot, journal and destination. Each run counts only the
    # journal rows committed after it starts (OF_SINCE), and the latency queries only rows in its load window.
    [[ "$(sf_count "$OF_DEST")" -gt 0 ]] || log "WARNING: $OF_DEST is empty (no Openflow snapshot yet)"
  fi
  if uses debezium; then
    dbz_cdc_init
    # Emptied, not deleted: see kafka_purge_topic. Also drops anything an aborted run left unconsumed.
    kafka_purge_topic "$DBZ_CDC_TOPIC"
    connect_size "$DBZ_CDC_CPU" "$DBZ_CDC_MEMORY" "$DBZ_CDC_HEAP"
    sf -f "$HERE/sql/debezium_cdc_reset.sql" > /dev/null
    [[ "$(sf_count DEBEZIUM_FULL_LOAD)" -gt 0 ]] ||
      log "WARNING: DEBEZIUM_FULL_LOAD is empty (no Debezium snapshot yet), so DEBEZIUM_REPLICATION starts empty"
  fi
}

# Stops the CDC pipelines of the tools in TOOLS and drops their idle slots. Merge tasks are suspended first.
cdc_stop_tools() {
  merge_tasks_suspend
  plugin stop
  if uses dms; then dms_delete_task "$DMS_CDC_TASK"; fi
  if uses debezium; then dbz_delete_connectors; fi
  drop_idle_slots
}

merge_tasks_suspend() {
  if uses dms; then sf -q "ALTER TASK IF EXISTS DMS_MERGE_TASK SUSPEND" > /dev/null; fi
  if uses debezium; then sf -q "ALTER TASK IF EXISTS DEBEZIUM_MERGE_TASK SUSPEND" > /dev/null; fi
  return 0
}

# Kafka consumer groups whose lag is sampled: both Transfers and the Snowflake connector, for the tools in TOOLS.
lag_groups() {
  plugin lag_groups
  if uses debezium; then
    dbz_cdc_init
    echo "$DBZ_CDC_GROUP"
  fi
  return 0
}

lag_reported() { # true once the exporter reports every group in lag_groups
  local g
  for g in $(lag_groups); do [[ "$(kafka_lag "$g")" =~ ^[0-9]+$ ]] || return 1; done
}

# Debezium (no_data: streams from when its slot is created) → the CDC topic → the Snowflake connector → DEBEZIUM_HISTORY.
# Both connectors come from kafka_connect_cdc.yaml as they are, except that the source gets a new name each run, so
# Debezium starts without stored offsets.
dbz_cdc_start() {
  local dir="$1" src
  dbz_cdc_init
  src="debezium-cdc-$(date -u +%Y%m%d%H%M%S)"
  kafka_topic_ensure "$DBZ_CDC_TOPIC" 1
  dbz_apply "$(dbz_cdc_connector sink)" .
  dbz_apply "$(dbz_cdc_connector source)" '.metadata.name = $n' --arg n "$src"
  echo "DBZ_SOURCE=$src" >> "$dir/state.env"
  dbz_wait_running "$DBZ_CDC_SINK"
  dbz_wait_running "$src"
}

cdc_start() {
  local dir="$1" arn conds=() cond
  log "starting CDC for $TOOLS"
  if uses dms; then
    arn="$(dms_create_task "$DMS_CDC_TASK" cdc dms_target_endpoint_arn streaming)"
    echo "DMS_CDC_ARN=$arn" >> "$dir/state.env"
    aws dms start-replication-task --replication-task-arn "$arn" --start-replication-task-type start-replication > /dev/null
    aws dms wait replication-task-running --filters "Name=replication-task-arn,Values=$arn"
    # DMS names its slot itself, so it's any active slot other than the other tools'.
    conds+=("bool_or(slot_name NOT IN ('$OF_SLOT'$(plugin slot_name | sed "s/.*/, '&'/" | tr -d '\n')) AND slot_name NOT LIKE 'debezium%' AND active)")
  fi
  for t in $(plugin_tools); do
    if has_hook "$t" cdc_start; then "${t}_cdc_start" "$dir"; fi
    conds+=("bool_or(slot_name = '$("${t}_slot_name")' AND active)")
  done
  if uses debezium; then
    dbz_cdc_start "$dir"
    conds+=("bool_or(slot_name = 'debezium' AND active)")
  fi
  if uses openflow; then
    of_start
    echo "OF_SINCE=$(now)" >> "$dir/state.env"
    conds+=("bool_or(slot_name = '$OF_SLOT' AND active)")
  fi
  cond="$(printf '%s AND ' "${conds[@]}")"
  wait_until 900 "the replication slots to be active" bash -c "[[ \$('$0' _pg \"SELECT ${cond% AND } FROM pg_replication_slots\") == t ]]"
  # Warm-up: the lag exporter only reports a consumer group once it has committed an offset, which needs a message,
  # and the Snowflake connector opens its channel on its first write. A no-op update to aid 1 runs through every
  # pipeline first, so lag is sampled from the start of the load. FILLER keeps its old timestamp, so the latency
  # queries never count this row. cdc_wait expects it in every history table.
  log "warm-up: one no-op update, then waiting for each tool and the Kafka lag exporter"
  psql_pod -c "UPDATE pgbench_accounts SET abalance = abalance WHERE aid = 1" > /dev/null
  echo "WARMUP=1" >> "$dir/state.env"
  plugin warmup_wait
  if uses dms; then wait_until 600 "DMS to land the warm-up row" bash -c "[[ \$('$0' _sf_count DMS_HISTORY) -ge 1 ]]"; fi
  if uses debezium; then wait_until 600 "Debezium to land the warm-up row" bash -c "[[ \$('$0' _sf_count DEBEZIUM_HISTORY) -ge 1 ]]"; fi
  if uses openflow; then
    # shellcheck disable=SC1091
    wait_until 600 "Openflow to land the warm-up row" bash -c "[[ \$('$0' _of_hist_count '$(source "$dir/state.env"; echo "$OF_SINCE")') -ge 1 ]]"
  fi
  if [[ -n "$(lag_groups)" ]]; then wait_until 600 "the exporter to report Kafka lag for $(lag_groups | tr '\n' ' ')" "$0" _lag_reported; fi
  if uses dms; then sf -q "ALTER TASK DMS_MERGE_TASK RESUME" > /dev/null; fi
  if uses debezium; then
    sf -f "$HERE/sql/debezium_cdc_start.sql" -D "dbz_wh=$DBZ_WH" > /dev/null
    sf -q "ALTER TASK DEBEZIUM_MERGE_TASK RESUME" > /dev/null
  fi
  sleep 30 # let the tools settle after the warm-up before load starts
}

# kubectl top for every pod and node, every SAMPLE_SECONDS. Used by CDC runs and snapshots.
kube_sampler_start() {
  local dir="$1"
  (
    set +e
    echo "sampled_utc,namespace,pod,cpu,memory" > "$dir/pods.csv"
    echo "sampled_utc,node,cpu,cpu_pct,memory,memory_pct" > "$dir/nodes.csv"
    while :; do
      ts="$(now)"
      kubectl --context "$KUBE_CONTEXT" top pods -A --no-headers 2>/dev/null | awk -v ts="$ts" '{print ts","$1","$2","$3","$4}' >> "$dir/pods.csv"
      kubectl --context "$KUBE_CONTEXT" top nodes --no-headers 2>/dev/null | awk -v ts="$ts" '{print ts","$1","$2","$3","$4","$5}' >> "$dir/nodes.csv"
      sleep "$SAMPLE_SECONDS"
    done
  ) &
  echo $! >> "$dir/samplers.pid"
}

samplers_start() {
  local dir="$1"
  (
    set +e
    echo "sampled_utc,slot_name,plugin,active,retained_bytes,unconfirmed_bytes" > "$dir/wal.csv"
    while :; do
      kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" exec pgbench -- psql -At -F, -c \
        "SELECT to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), slot_name, plugin, active,
                pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
         FROM pg_replication_slots" >> "$dir/wal.csv" 2>/dev/null
      sleep "$SAMPLE_SECONDS"
    done
  ) &
  echo $! >> "$dir/samplers.pid"
  kube_sampler_start "$dir"
  (
    set +e
    echo "sampled_utc,consumer_group,lag" > "$dir/kafka_lag.csv"
    while :; do
      ts="$(now)"
      for g in $(lag_groups); do
        echo "$ts,$g,$(kafka_lag "$g")" >> "$dir/kafka_lag.csv"
      done
      sleep "$SAMPLE_SECONDS"
    done
  ) &
  echo $! >> "$dir/samplers.pid"
}

samplers_stop() {
  local dir="$1"
  [[ -f "$dir/samplers.pid" ]] || return 0
  xargs kill < "$dir/samplers.pid" 2>/dev/null || true
  rm -f "$dir/samplers.pid"
}

cdc_load() {
  local dir="$1"
  log "pgbench: scale $LOAD_SCALE, $CLIENTS clients, $THREADS threads, ${DURATION}s"
  pod_job load > "$dir/pgbench.log" <<EOF
set -e
date -u +%Y-%m-%dT%H:%M:%SZ > /tmp/load.start
pgbench -f /scripts/custom_tpcb.sql -s $LOAD_SCALE -c $CLIENTS -j $THREADS -T $DURATION -M prepared -P 5 -n
date -u +%Y-%m-%dT%H:%M:%SZ > /tmp/load.end
EOF
  local txns
  txns="$(sed -n 's/^number of transactions actually processed: \([0-9]*\).*/\1/p' "$dir/pgbench.log")"
  [[ -n "$txns" ]] || die "couldn't read the transaction count from $dir/pgbench.log"
  {
    echo "LOAD_START=$(kn exec pgbench -- cat /tmp/load.start)"
    echo "LOAD_END=$(kn exec pgbench -- cat /tmp/load.end)"
    echo "TXNS=$txns"
  } >> "$dir/state.env"
  log "pgbench done: $txns transactions ($(grep -E '^tps' "$dir/pgbench.log" | head -1))"
}

# Each pgbench transaction updates one pgbench_accounts row, so each history table should end with TXNS rows.
# Done when, per tool, the history table has them all and the count has held steady for 3 minutes (which covers DMS's
# 60-second file batches), plus:
# - Plugin tools: their caught_up hook, if they have one.
# - DMS: Snowpipe has nothing pending, the stream is empty and no merge is running.
# - Debezium: the stream is empty and no merge is running. The Snowflake connector's Kafka lag is sampled but isn't a
#   condition: it commits offsets from what Snowflake has acknowledged, which can trail what has landed.
cdc_wait() {
  local dir="$1" txns d_hist=-1 z_hist=-1 d_prev=-1 z_prev=-1 d_stable=0 z_stable=0
  local o_hist=-1 o_prev=-1 o_stable=0 o_done t
  local -A p_hist=() p_prev=() p_stable=()
  local p_done d_done z_done start=$SECONDS status
  # shellcheck disable=SC1091
  source "$dir/state.env"
  txns=$((TXNS + ${WARMUP:-0})) # pgbench transactions plus the warm-up row from cdc_start
  log "waiting for $TOOLS to land $txns changes"
  while :; do
    ((SECONDS - start > CATCHUP_TIMEOUT)) && { log "catch-up timed out. Measuring what landed."; break; }
    # A tool not in TOOLS counts as done. Counts are -1 on a failed query, so one Snowflake hiccup doesn't end a run.
    p_done=1 d_done=1 z_done=1 o_done=1 status=""
    for t in $(plugin_tools); do
      p_hist[$t]="$("${t}_hist_count" || echo -1)"
      [[ "${p_hist[$t]}" == "${p_prev[$t]:--1}" ]] && p_stable[$t]=$((${p_stable[$t]:-0} + 30)) || p_stable[$t]=0
      p_prev[$t]="${p_hist[$t]}"
      if ((p_hist[$t] >= txns && p_stable[$t] >= 180)) && { ! has_hook "$t" caught_up || "${t}_caught_up"; }; then
        status+=" $t ${p_hist[$t]} (done=1)"
      else
        p_done=0
        status+=" $t ${p_hist[$t]} (done=0)"
      fi
    done
    if uses dms; then
      d_hist="$(sf_count DMS_HISTORY || echo -1)"
      [[ "$d_hist" == "$d_prev" ]] && d_stable=$((d_stable + 30)) || d_stable=0
      d_prev="$d_hist" d_done=0
      if ((d_hist >= txns && d_stable >= 180)) &&
        [[ "$(sf_val "SELECT PARSE_JSON(SYSTEM\$PIPE_STATUS('DMS_CDC_PIPE')):pendingFileCount::INT AS N")" == 0 ]] &&
        merge_idle DMS_HISTORY_STREAM DMS_MERGE_TASK; then
        d_done=1
      fi
      status+=" dms $d_hist (done=$d_done)"
    fi
    if uses debezium; then
      z_hist="$(sf_count DEBEZIUM_HISTORY || echo -1)"
      [[ "$z_hist" == "$z_prev" ]] && z_stable=$((z_stable + 30)) || z_stable=0
      z_prev="$z_hist" z_done=0
      if ((z_hist >= txns && z_stable >= 180)) && merge_idle DEBEZIUM_HISTORY_STREAM DEBEZIUM_MERGE_TASK; then
        z_done=1
      fi
      status+=" debezium $z_hist (done=$z_done)"
    fi
    if uses openflow; then
      o_hist="$(of_hist_count "$OF_SINCE" || echo -1)"
      [[ "$o_hist" == "$o_prev" ]] && o_stable=$((o_stable + 30)) || o_stable=0
      o_prev="$o_hist" o_done=0
      if ((o_hist >= txns && o_stable >= 180)) && of_merged; then o_done=1; fi
      status+=" openflow $o_hist (done=$o_done)"
    fi
    log "history rows of $txns:$status"
    ((p_done && d_done && z_done && o_done)) && break
    sleep 30
  done
  echo "CAUGHT_UP=$(now)" >> "$dir/state.env"
  {
    echo "table,rows,expected"
    for t in $(plugin_tools); do echo "$("${t}_hist_table"),${p_hist[$t]:--1},$txns"; done
    if uses dms; then echo "DMS_HISTORY,$d_hist,$txns"; fi
    if uses debezium; then echo "DEBEZIUM_HISTORY,$z_hist,$txns"; fi
    if uses openflow; then echo "OPENFLOW_JOURNAL,$o_hist,$txns"; fi
  } > "$dir/row_counts.csv"
  for t in $(plugin_tools); do
    ((${p_hist[$t]:--1} > txns)) && log "WARNING: $t's $("${t}_hist_table") has ${p_hist[$t]} rows for $txns changes"
  done
  ((d_hist > txns)) && log "WARNING: DMS_HISTORY has $d_hist rows for $txns changes (duplicate loads?)"
  ((z_hist > txns)) && log "WARNING: DEBEZIUM_HISTORY has $z_hist rows for $txns changes (a restarted task?)"
  ((o_hist > txns)) && log "WARNING: Openflow's journal has $o_hist rows for $txns changes"
  return 0
}

cdc_measure() {
  local dir="$1"
  # shellcheck disable=SC1091
  source "$dir/state.env"
  log "measuring latency"
  sf_fill_csv latency_summary.sql "$(latency_sources)" -D "load_start=$LOAD_START" -D "load_end=$LOAD_END" > "$dir/latency_summary.csv"
  sf_fill_csv latency_minutes.sql "$(latency_sources)" -D "load_start=$LOAD_START" -D "load_end=$LOAD_END" > "$dir/latency_minutes.csv"
  if uses dms; then
    sf_file_csv task_history.sql -D "task=DMS_MERGE_TASK" -D "start=$LOAD_START" -D "end=$CAUGHT_UP" > "$dir/dms_merge_task.csv"
  fi
  if uses debezium; then
    sf_file_csv task_history.sql -D "task=DEBEZIUM_MERGE_TASK" -D "start=$LOAD_START" -D "end=$CAUGHT_UP" > "$dir/debezium_merge_task.csv"
  fi
  sf_fill_csv warehouse_queries.sql "$(warehouse_history_sources "$LOAD_START" "$CAUGHT_UP")" > "$dir/warehouse_queries.csv"
  column -s, -t < "$dir/latency_summary.csv" >&2
}

cloudwatch_csv() { # label namespace metric start end out dimensions...
  local label="$1" ns="$2" metric="$3" start="$4" end="$5" out="$6"
  shift 6
  aws cloudwatch get-metric-statistics --namespace "$ns" --metric-name "$metric" --dimensions "$@" \
    --start-time "$start" --end-time "$end" --period 60 --statistics Average Maximum --output json |
    jq -r --arg m "$label" '.Datapoints | sort_by(.Timestamp)[] | [$m, .Timestamp, .Average, .Maximum] | @csv' >> "$out"
}

cdc_cloudwatch() {
  local dir="$1" inst task rds m out
  # shellcheck disable=SC1091
  source "$dir/state.env"
  log "pulling CloudWatch metrics"
  local start end
  start="$(date -u -j -v-5M -f %Y-%m-%dT%H:%M:%SZ "$LOAD_START" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$LOAD_START - 5 min" +%Y-%m-%dT%H:%M:%SZ)"
  end="$CAUGHT_UP"
  rds="$(rds_host | cut -d. -f1)"
  out="$dir/cloudwatch.csv"
  echo "metric,timestamp,average,maximum" > "$out"
  if uses dms; then
    inst="$(aws dms describe-replication-instances --query 'ReplicationInstances[0].ReplicationInstanceIdentifier' --output text \
      --filters "Name=replication-instance-arn,Values=$(tf_out dms_replication_instance_arn)")"
    task="${DMS_CDC_ARN##*:}"
    # DMS doesn't publish CPU credit metrics for t3 instances, so CPUCreditBalance and CPUCreditUsage always come back empty.
    for m in CPUUtilization FreeableMemory SwapUsage NetworkTransmitThroughput; do
      cloudwatch_csv "dms_instance_$m" AWS/DMS "$m" "$start" "$end" "$out" "Name=ReplicationInstanceIdentifier,Value=$inst" || true
    done
    for m in CDCLatencySource CDCLatencyTarget CDCIncomingChanges CDCChangesDiskTarget; do
      cloudwatch_csv "dms_task_$m" AWS/DMS "$m" "$start" "$end" "$out" "Name=ReplicationInstanceIdentifier,Value=$inst" "Name=ReplicationTaskIdentifier,Value=$task" || true
    done
  fi
  for m in CPUUtilization ReadIOPS WriteIOPS NetworkTransmitThroughput ReplicationSlotDiskUsage TransactionLogsDiskUsage OldestReplicationSlotLag; do
    cloudwatch_csv "rds_$m" AWS/RDS "$m" "$start" "$end" "$out" "Name=DBInstanceIdentifier,Value=$rds" || true
  done
  [[ "$(wc -l < "$out")" -gt 1 ]] || log "WARNING: no CloudWatch datapoints. Check the dimensions in cdc_cloudwatch."
  if uses dms && ! grep -q '^"dms_task_' "$out"; then
    log "WARNING: no DMS task metrics. ReplicationTaskIdentifier may need the task's resource ID."
  fi
  return 0
}

record_metadata() {
  local dir="$1"
  {
    echo "git_commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "tools=$TOOLS"
    plugin metadata
    if k -n kafka get kafka artie-kafka > /dev/null 2>&1; then
      echo "kafka_version=$(k -n kafka get kafka artie-kafka -o jsonpath='{.spec.kafka.version}')"
      echo "kafka_num_partitions=$(k -n kafka get kafka artie-kafka -o jsonpath='{.spec.kafka.config.num\.partitions}') (empty = broker default of 1)"
    fi
    if uses openflow; then of_metadata; fi
    echo "node_types=$(k get nodes -o jsonpath='{.items[*].metadata.labels.node\.kubernetes\.io/instance-type}')"
    if uses dms; then
      echo "dms_instance_class=$(aws dms describe-replication-instances --query 'ReplicationInstances[0].[ReplicationInstanceClass,EngineVersion]' --output text \
        --filters "Name=replication-instance-arn,Values=$(tf_out dms_replication_instance_arn)")"
      echo "dms_wh=$DMS_WH"
    fi
    echo "rds=$(aws rds describe-db-instances --db-instance-identifier "$(rds_host | cut -d. -f1)" --query 'DBInstances[0].[DBInstanceClass,EngineVersion]' --output text)"
    echo "pgbench=$(kn exec pgbench -- pgbench --version)"
    echo "pgbench_args=-s $LOAD_SCALE -c $CLIENTS -j $THREADS -T $DURATION -M prepared"
    if uses debezium; then
      echo "dbz_wh=$DBZ_WH"
      k -n kafka get kafkaconnect connect -o json | jq -r '"kafka_connect=version \(.spec.version), replicas \(.spec.replicas), cpu_request \(.spec.resources.requests.cpu), memory \(.spec.resources.requests.memory), heap \(.spec.jvmOptions["-Xmx"]), image \(.spec.build.output.image)",
        (.status.connectorPlugins[]? | select(.class | test("PostgresConnector|SnowflakeStreamingSinkConnector")) | "connect_plugin=\(.class) \(.version)")'
      echo "kafka_connect_node=$(k -n kafka get "$(connect_pod)" -o jsonpath='{.spec.nodeName}')"
    fi
  } > "$dir/metadata.txt"
  sf_json -q "SHOW WAREHOUSES LIKE 'BENCHMARK_WH%'" | jq -r '.[] | "warehouse=\(.name) \(.size) \(.type) auto_suspend=\(.auto_suspend)"' >> "$dir/metadata.txt" || true
}

step_cdc_run() {
  local i="$1" dir="$RESULTS/cdc-$1"
  mkdir -p "$dir"
  : > "$dir/state.env"
  cdc_reset
  cdc_start "$dir"
  samplers_start "$dir"
  trap 'samplers_stop "'"$dir"'"' EXIT
  cdc_load "$dir"
  cdc_wait "$dir"
  sleep 120 # keep sampling while the slots drain WAL
  samplers_stop "$dir"
  trap - EXIT
  merge_tasks_suspend
  cdc_measure "$dir"
  cdc_cloudwatch "$dir"
  record_metadata "$dir"
  log "CDC run $i done: $dir"
}

step_cdc() {
  local i
  for ((i = 1; i <= CDC_RUNS; i++)); do step_cdc_run "$i"; done
  cdc_stop_tools
}

# End-to-end check of the CDC pipelines in TOOLS before the real runs: N single-row updates, each its own transaction, then
# the same catch-up checks and latency query as a CDC run. Results go to $RESULTS/cdc-smoke and aren't benchmark data.
step_cdc_smoke() {
  local n="${1:-100}" dir="$RESULTS/cdc-smoke"
  rm -rf "$dir" && mkdir -p "$dir"
  : > "$dir/state.env"
  cdc_reset
  cdc_start "$dir"
  samplers_start "$dir"
  trap 'samplers_stop "'"$dir"'"' EXIT
  log "updating $n rows, one transaction each"
  {
    echo "LOAD_START=$(now)"
    seq 1 "$n" | awk '{printf "UPDATE pgbench_accounts SET abalance = abalance + 1, filler = CURRENT_TIMESTAMP::text WHERE aid = %d;\n", $1 * 999983 % 100000000 + 1}' |
      kn exec -i pgbench -- psql -v ON_ERROR_STOP=1 -q > /dev/null
    echo "LOAD_END=$(now)"
    echo "TXNS=$n"
  } >> "$dir/state.env"
  cdc_wait "$dir"
  samplers_stop "$dir"
  trap - EXIT
  merge_tasks_suspend
  cdc_measure "$dir"
  cdc_cloudwatch "$dir"
  record_metadata "$dir"
  cdc_stop_tools
  # Every mode should have exactly n rows from this test: history has one per update, replication one per account.
  awk -F, -v n="$n" 'NR > 1 { gsub(/"/, ""); ok = ($3 == n); bad += !ok; print $1, $2, $3 " rows", (ok ? "OK" : "MISMATCH") } END { exit bad > 0 }' \
    "$dir/latency_summary.csv" || die "cdc_smoke: a pipeline didn't land exactly $n rows. See $dir."
  [[ "$(awk 'END {print NR - 1}' "$dir/latency_summary.csv")" == $(($(tool_count) * 2)) ]] ||
    die "cdc_smoke: expected a history and a replication row per tool in $dir/latency_summary.csv"
  log "cdc_smoke passed: $TOOLS landed all $n changes in history and replication"
}

# Stops everything a CDC run or Debezium snapshot starts. For an aborted run; the steps clean up after themselves.
step_cdc_stop() {
  local dir
  for dir in "$RESULTS"/cdc-* "$RESULTS"/snapshot-*; do
    [[ -f "$dir/samplers.pid" ]] && samplers_stop "$dir"
  done
  cdc_stop_tools
  log "CDC stopped for $TOOLS: merge tasks suspended, pipelines stopped, idle slots dropped"
}

# Snowflake credits from ACCOUNT_USAGE, one row per clock hour (see run/sql/cost.sql). Metering lags up to 3 hours, so this
# runs separately and can be repeated; it warns while any hour may still change.
# - <dir>/cost.csv for each CDC run and Debezium snapshot: the hours the run started and finished in, and those between.
#   Start runs on the hour so each run's hours are its own.
# - cost_hourly.csv at the run root: every hour from the first run's start to the last run's end, for runs that share
#   hours.
step_cost() {
  local dir start end first="" last="" unsettled=0 whs args
  whs="$(tool_warehouses | sed "s/.*/'&'/" | paste -sd, -)"
  local of_db=""
  if uses openflow; then of_db="$OF_DB"; fi
  args=(-D "db=$SF_DB" -D "schema=$SF_SCHEMA" -D "of_db=$of_db" -D "pools=$OF_POOLS")
  for dir in "$RESULTS"/cdc-* "$RESULTS"/snapshot-debezium-* "$RESULTS"/snapshot-openflow-*; do
    [[ -f "$dir/state.env" ]] || continue
    read -r start end < <(
      # shellcheck disable=SC1091
      source "$dir/state.env"
      echo "${LOAD_START:-${SNAPSHOT_START:-}} ${CAUGHT_UP:-${SNAPSHOT_END:-}}"
    )
    [[ -n "$start" && -n "$end" ]] || { log "WARNING: $dir has no start and end in state.env; skipped"; continue; }
    sf_fill_csv cost.sql "$whs" "${args[@]}" -D "start=$start" -D "end=$end" > "$dir/cost.csv"
    grep -q '"may change"' "$dir/cost.csv" && unsettled=1
    log "$dir/cost.csv: $(cost_summary "$dir/cost.csv")"
    [[ -z "$first" || "$start" < "$first" ]] && first="$start"
    [[ -z "$last" || "$end" > "$last" ]] && last="$end"
  done
  [[ -n "$first" ]] || { log "no runs with state.env in $RESULTS"; return 0; }
  sf_fill_csv cost.sql "$whs" "${args[@]}" -D "start=$first" -D "end=$last" > "$RESULTS/cost_hourly.csv"
  log "$RESULTS/cost_hourly.csv: $(cost_summary "$RESULTS/cost_hourly.csv")"
  # ACCOUNT_USAGE can also leave a recent hour out entirely, which STATUS can't show.
  if ((unsettled)) || (($(date -u +%s) - $(iso_epoch "$last") < 4 * 3600)); then
    log "WARNING: some hours may not have settled yet. Rerun ./run/bench.sh cost after $(date -u -r $(($(iso_epoch "$last") + 4 * 3600)) +%H:%MZ 2>/dev/null || date -u -d "@$(($(iso_epoch "$last") + 4 * 3600))" +%H:%MZ)."
  fi
}

# Total credits per KIND and NAME in a cost.csv, on one line.
cost_summary() {
  tr -d '"' < "$1" | awk -F, 'NR > 1 {c[$1 " " $2] += $4} END {for (k in c) printf "%s %.3f; ", k, c[k]}'
}

iso_epoch() { date -j -u -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }

step_teardown() {
  log "stopping everything the benchmark started for $TOOLS"
  merge_tasks_suspend || true
  plugin stop
  if uses dms; then
    dms_delete_task "$DMS_CDC_TASK"
    dms_delete_task "$DMS_FULL_LOAD_TASK"
    sf -q "ALTER PIPE IF EXISTS DMS_CDC_PIPE SET PIPE_EXECUTION_PAUSED = TRUE" > /dev/null || true
    sf -q "ALTER PIPE IF EXISTS DMS_FULL_LOAD_PIPE SET PIPE_EXECUTION_PAUSED = TRUE" > /dev/null || true
  fi
  if uses debezium; then dbz_delete_connectors || true; fi
  if uses openflow; then
    # Stopped, not dropped: the deployment, runtime and destination stay (see Teardown in openflow/README.md). Its slot
    # would hold WAL while it's stopped, so it's dropped; the next start then needs a new snapshot.
    if [[ "$(of_status)" == RUNNING ]]; then of_q "ALTER OPENFLOW CONNECTOR $OF_CONNECTOR STOP"; of_wait_status 900 STOPPED || true; fi
    psql_pod -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '$OF_SLOT' AND NOT active" > /dev/null || true
  fi
  drop_idle_slots || true
  kn delete pod pgbench --ignore-not-found > /dev/null
  kn delete secret pgbench-credentials --ignore-not-found > /dev/null
  kn delete configmap pgbench-scripts --ignore-not-found > /dev/null
  log "done. Infrastructure is still up. See the teardown section of run/README.md."
}

# ---------------------------------------------------------------------------------------------------------- main

case "${1:-help}" in
  # Internal helpers, called through bash -c inside wait_until.
  _pg) psql_pod -c "$2" ;;
  _sf_count) sf_count "$2" ;;
  _sf_val) sf_val "$2" ;;
  _kafka_lag) kafka_lag "$2" ;;
  _sf_table_exists) sf_table_exists "$2" ;;
  _connect_rest) connect_rest "$2" ;;
  _connect_ready) connect_ready ;;
  _lag_reported) lag_reported ;;
  _of_status) of_status ;;
  _of_hist_count) of_hist_count "$2" ;;

  check) step_check ;;
  pg_pod) step_pg_pod ;;
  pg_init) step_pg_init ;;
  pg_vacuum) step_pg_vacuum ;;
  sf_setup) step_sf_setup ;;
  row_timestamps) step_row_timestamps ;;
  snapshots) step_snapshots ;;
  snapshot_dms) mkdir -p "$RESULTS"; step_snapshot_dms "${2:?run number}" ;;
  snapshot_debezium) mkdir -p "$RESULTS"; step_snapshot_debezium "${2:?run number}" ;;
  snapshot_openflow) mkdir -p "$RESULTS"; step_snapshot_openflow "${2:?run number}" ;;
  snapshot_dms_cpu) mkdir -p "$RESULTS"; snapshot_dms_cpu "${2:?run number}" "${3:?start time, ISO 8601 UTC}" "${4:-}" ;;
  snapshot_*)
    # A plugin tool's snapshot step: step_snapshot_<tool> in its bench_<tool>.sh.
    declare -F "step_$1" > /dev/null || { echo "unknown step: $1" >&2; exit 1; }
    mkdir -p "$RESULTS"
    "step_$1" "${2:?run number}"
    ;;
  cdc) step_cdc ;;
  cdc_run) step_cdc_run "${2:?run number}" ;;
  cdc_smoke) step_cdc_smoke "${2:-100}" ;;
  cdc_stop) step_cdc_stop ;;
  cost) step_cost ;;
  teardown) step_teardown ;;
  all)
    step_check
    step_pg_pod
    step_pg_init
    step_sf_setup
    step_row_timestamps
    step_snapshots
    step_cdc
    ;;
  *)
    sed -n '2,7p' "$0"
    exit 1
    ;;
esac
