#!/usr/bin/env bash
# End-to-end write benchmark: local Postgres -> Artie Reader (Artie's raw record format) -> local Kafka -> Artie Transfer
# -> BigQuery.
# Transfer runs once without the partition predicate (arm a) and once with it (arm b), on a steady five-minute-style
# workload. The drain step then compares raw records with Debezium JSON on a 1.2M-change backlog. See README.md.
#
#   PROJECT=my-project ./run.sh setup       # once, creates daily_1095
#   PROJECT=my-project ./local.sh           # every step
#   PROJECT=my-project ./local.sh report_local    # selected steps
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/run.sh"

# Artie Reader and Transfer checkouts for the build step. Alternatively, put prebuilt binaries in results/local/bin and
# skip the build step.
READER_DIR="${READER_DIR:-}"
TRANSFER_DIR="${TRANSFER_DIR:-}"
REF="${REF:-origin/master}"
CREDS="${CREDS:-$HOME/.config/gcloud/application_default_credentials.json}"
FLUSH="${FLUSH:-30}"       # Transfer flush interval and workload batch interval, in seconds
BATCHES="${BATCHES:-24}"   # batches per arm
DRAIN_INSERTS="${DRAIN_INSERTS:-1000000}"
DRAIN_DELETES="${DRAIN_DELETES:-10000}"
DRAIN_BUFFER="${DRAIN_BUFFER:-50000}" # Transfer bufferRows for the drain, so it flushes by size
# Drain deletes take rows from the middle of the day before the anchor; the steady arms delete from its end.
[ $((RPD / 2 + DRAIN_DELETES)) -le $((RPD - 2 * BATCHES * 50)) ] || { echo "DRAIN_DELETES is too large for RPD" >&2; exit 1; }
LOCAL="$OUT/local"
mkdir -p "$LOCAL/bin"

dc() { docker compose -f "$DIR/docker-compose.yaml" -p bq-merge-bench "$@"; }
psql_exec() { dc exec -T postgres psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done' EXIT

# Builds REF of a checkout from a clean export, so local branches and edits don't leak in.
build() { # name dir [out_dir]
  local src="$LOCAL/src/$1"
  rm -rf "$src" && mkdir -p "$src"
  git -C "$2" fetch -q origin
  git -C "$2" archive "$REF" | tar -x -C "$src"
  git -C "$2" rev-parse --short "$REF" >"$LOCAL/$1.sha"
  (cd "$src" && GOWORK=off go build -o "${3:-$LOCAL/bin}/$1" .)
  log "built $1 at $(cat "$LOCAL/$1.sha")"
}

step_up() {
  dc up -d --wait
}

step_build() {
  : "${READER_DIR:?set READER_DIR to an Artie Reader checkout}" "${TRANSFER_DIR:?set TRANSFER_DIR to an Artie Transfer checkout}"
  build reader "$READER_DIR"
  build transfer "$TRANSFER_DIR"
}

step_seed() {
  psql_exec -v anchor="$ANCHOR" -v rpd="$RPD" <"$DIR/sql/postgres_schema.sql"
  rm -f "$LOCAL"/*.offset
  log "seeded Postgres with $((2 * RPD)) rows"
}

batch() { # k
  psql_exec -v anchor="$ANCHOR" -v rpd="$RPD" -v k="$1" <"$DIR/sql/postgres_batch.sql"
}

# Records every statsd packet Transfer sends; report reads its flush timings.
statsd() { # file
  python3 -I -u - "$1" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 18125))
with open(sys.argv[1], "a") as f:
    while True:
        f.write(s.recv(65535).decode() + "\n")
        f.flush()
PY
  STATSD_PID=$!
  PIDS+=("$STATSD_PID")
}

kafka() { dc exec -T kafka /opt/kafka/bin/"$@" --bootstrap-server localhost:59092; }

create_topic() { kafka kafka-topics.sh --create --if-not-exists --topic "$1" >/dev/null; }

end_offset() { kafka kafka-get-offsets.sh --topic "$1" | awk -F: '{s += $3} END {print s + 0}'; }

topic_bytes() { kafka kafka-log-dirs.sh --describe --topic-list "$1" | grep -o '"size":[0-9]*' | awk -F: '{s += $2} END {print s + 0}'; }

# CPU seconds a process has used: user plus system ticks from /proc on Linux, else ps' [[dd-]hh:]mm:ss.ss.
cpu_seconds() {
  if [ -r "/proc/$1/stat" ]; then
    awk -v hz="$(getconf CLK_TCK)" '{print ($14 + $15) / hz}' "/proc/$1/stat"
  else
    ps -o time= -p "$1" | awk -F'[-:]' '{s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s}'
  fi
}

transfer_config() { # name topic table predicate buffer_rows flush_seconds
  local partition=""
  [ "$4" = yes ] && partition="
      bigQueryPartitionSettings:
        partitionType: time
        partitionField: created_at
        partitionBy: daily"
  cat >"$LOCAL/transfer_$1.yaml" <<YAML
mode: replication
outputSource: bigquery
queue: kafka
flushIntervalSeconds: $6
bufferRows: $5
flushSizeKb: 1000000
kafka:
  bootstrapServer: localhost:59092
  groupID: bench-$RUN_ID-$1
  disableTLS: true
  topicConfigs:
    - db: $DATASET
      schema: public
      tableName: $3
      topic: $2
      cdcFormat: debezium.postgres
      cdcKeyFormat: org.apache.kafka.connect.json.JsonConverter$partition
bigquery:
  pathToCredentials: $CREDS
  projectID: $PROJECT
  defaultDataset: $DATASET
  location: $LOCATION
telemetry:
  metrics:
    provider: datadog
    settings:
      namespace: "transfer."
      addr: "127.0.0.1:18125"
YAML
}

reader_config() { # name topic_prefix slot raw
  cat >"$LOCAL/reader_$1.yaml" <<YAML
source: postgresql
postgresql:
  host: localhost
  port: 54329
  username: postgres
  password: postgres
  database: postgres
  disableSSL: true
  tables:
    - name: activity
      schema: public
  streaming:
    enabled: true
    replicationSlot: $3
    publication: $3
    offsetFile: $LOCAL/$3.offset
kafka:
  bootstrapServers: localhost:59092
  topicPrefix: $2
  rawMessages: $4
  disableTLS: true
YAML
}

start_transfer() { # name
  : >"$LOCAL/statsd_$1.log"
  statsd "$LOCAL/statsd_$1.log"
  "$LOCAL/bin/transfer" --config "$LOCAL/transfer_$1.yaml" >"$LOCAL/transfer_$1.log" 2>&1 &
  TRANSFER_PID=$!
  PIDS+=("$TRANSFER_PID")
}

# Waits until Reader has created its replication slot, so no change made after this is missed.
wait_slot() { # slot
  local waited=0
  until [ "$(dc exec -T postgres psql -U postgres -At -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$1'")" = 1 ]; do
    [ "$waited" -lt 120 ] || { log "Reader did not create slot $1" >&2; return 1; }
    sleep 2
    waited=$((waited + 2))
  done
}

start_reader() { # name
  "$LOCAL/bin/reader" --config "$LOCAL/reader_$1.yaml" >"$LOCAL/reader_$1.log" 2>&1 &
  READER_PID=$!
  PIDS+=("$READER_PID")
}

stop() { # pid...
  kill "$@" 2>/dev/null || true
  wait "$@" 2>/dev/null || true
}

check_flushed() { # name
  grep -q "flush" "$LOCAL/statsd_$1.log" || { log "no flush metrics from Transfer, see $LOCAL/transfer_$1.log"; return 1; }
}

# Steady workload: Reader writes raw records, one 500-change batch per flush.
run_arm() { # arm k0
  local arm=$1 k0=$2 topic="bench_$1.public.activity" predicate=no
  [ "$arm" = b ] && predicate=yes
  clone daily_1095 "activity_$arm"
  create_topic "$topic"
  transfer_config "$arm" "$topic" "activity_$arm" "$predicate" 1000000 "$FLUSH"
  reader_config "$arm" "bench_$arm" bench_slot true

  start_transfer "$arm"
  sleep 20 # let Transfer join its consumer group before anything is produced
  start_reader "$arm"
  wait_slot bench_slot

  date -u +"%F %T" >"$LOCAL/start_$arm"
  for k in $(seq "$k0" $((k0 + BATCHES - 1))); do
    batch "$k"
    log "arm $arm batch $k"
    sleep "$FLUSH"
  done
  sleep $((FLUSH * 3)) # let the last batch flush
  stop "$READER_PID" "$TRANSFER_PID" "$STATSD_PID"
  check_flushed "$arm"
}

step_arm_a() { run_arm a 0; }
step_arm_b() { run_arm b "$BATCHES"; }

# Waits until the topic holds want records: one per row the workload changed. Prints the count.
wait_produced() { # topic want
  local n=0 waited=0
  until [ "$n" -ge "$2" ]; do
    [ "$waited" -lt 1800 ] || { log "Reader wrote $n of $2 records to $1" >&2; return 1; }
    sleep 10
    waited=$((waited + 10))
    n=$(end_offset "$1")
  done
  echo "$n"
}

# Raw records vs Debezium JSON. Two Readers capture the same changes, one per format, into their own topics. Transfer
# then drains each topic into its own clone of daily_1095, with the partition predicate on, as a customer would run it.
# The backlog makes Transfer's decoding visible next to BigQuery's merge time; a steady trickle hides it.
step_drain() {
  local fmt raw n want count=""
  # Reader always serves its liveness probe on :8081, so the two Readers run one at a time. Each first creates its
  # replication slot, so both slots hold the workload's changes.
  for fmt in raw json; do
    raw=false
    [ "$fmt" = raw ] && raw=true
    create_topic "drain_$fmt.public.activity"
    reader_config "drain_$fmt" "drain_$fmt" "bench_drain_$fmt" "$raw"
    start_reader "drain_$fmt"
    wait_slot "bench_drain_$fmt"
    stop "$READER_PID"
  done

  psql_exec -v anchor="$ANCHOR" -v rpd="$RPD" -v inserts="$DRAIN_INSERTS" -v deletes="$DRAIN_DELETES" \
    <"$DIR/sql/postgres_drain.sql" >"$LOCAL/drain_counts"
  awk '$1 == "updated" {print $2}' "$LOCAL/drain_counts" >"$LOCAL/drain_updated"
  want=$(awk '{s += $2} END {print s}' "$LOCAL/drain_counts")
  log "drain workload applied: $(tr '\n' ' ' <"$LOCAL/drain_counts")"

  for fmt in raw json; do
    start_reader "drain_$fmt"
    n=$(wait_produced "drain_$fmt.public.activity" "$want") || return 1
    stop "$READER_PID"
    log "Reader wrote $n $fmt records"
    [ -z "$count" ] || [ "$count" = "$n" ] || { log "raw and JSON topics differ: $count vs $n records"; return 1; }
    count=$n
  done

  for fmt in raw json; do
    local name="drain_$fmt" topic="drain_$fmt.public.activity" started finished lag
    clone daily_1095 "activity_$name"
    transfer_config "$name" "$topic" "activity_$name" yes "$DRAIN_BUFFER" 10
    date -u +"%F %T" >"$LOCAL/start_$name"
    started=$(date +%s)
    start_transfer "$name"
    # Transfer commits offsets after each flush, so a zero lag means every record is merged into BigQuery.
    lag=-1
    until [ "$lag" = 0 ]; do
      sleep 2
      kill -0 "$TRANSFER_PID" 2>/dev/null || { log "Transfer exited, see $LOCAL/transfer_$name.log"; return 1; }
      lag=$(kafka kafka-consumer-groups.sh --describe --group "bench-$RUN_ID-$name" 2>/dev/null |
        awk -v t="$topic" '$2 == t {s += ($6 == "-" ? -1 : $6); n++} END {print n ? s : -1}') || lag=-1
    done
    finished=$(date +%s)
    {
      echo "records=$(end_offset "$topic")"
      echo "kafka_bytes=$(topic_bytes "$topic")"
      echo "drain_seconds=$((finished - started))"
      echo "transfer_cpu_seconds=$(cpu_seconds "$TRANSFER_PID")"
    } >"$LOCAL/$name.txt"
    stop "$TRANSFER_PID" "$STATSD_PID"
    check_flushed "$name"
    log "$name: $(tr '\n' ' ' <"$LOCAL/$name.txt")"
  done
}

# Prints flushes, p50, p95, mean and max of Transfer's flush timing in ms, or 0 and NULLs without flushes.
flush_values() { # name
  grep "^transfer.flush:" "$LOCAL/statsd_$1.log" 2>/dev/null | grep "table:activity_$1" | sed -E 's/^transfer\.flush:([0-9.]+)\|.*/\1/' |
    sort -n | awk '{v[NR]=$1; s+=$1} END {if (NR) printf "%d, %.1f, %.1f, %.1f, %.1f", NR, v[int((NR+1)/2)], v[int(NR*0.95+0.5)>0?int(NR*0.95+0.5):1], s/NR, v[NR]; else printf "0, NULL, NULL, NULL, NULL"}'
}

step_report_local() {
  local expected=$((1095 * RPD + BATCHES * 300 - BATCHES * 50)) drain_expected=""
  local since names="" n rows="" sep="" format predicate records kafka_bytes drain_seconds transfer_cpu_seconds
  for n in a b drain_raw drain_json; do
    [ -f "$LOCAL/start_$n" ] && names="$names $n"
  done
  [ -n "$names" ] || { log "no local runs to report"; return 1; }
  since=$(cat "$LOCAL"/start_* | sort | head -n1)
  [ -f "$LOCAL/drain_counts" ] && drain_expected=$((1095 * RPD + $(awk '$1 == "inserted" {print $2}' "$LOCAL/drain_counts") - $(awk '$1 == "deleted" {print $2}' "$LOCAL/drain_counts")))

  ensure_results
  # With JOBS_BY_USER, CREDS must be the bq account (the default ADC file is), or Transfer's merges are not listed.
  persist_merges "SELECT '$RUN_ID' AS run_id, 'local' AS source,
  IF(STARTS_WITH(destination_table.table_id, 'activity_drain_'), 'drain', 'steady') AS scenario,
  destination_table.table_id AS tbl, REGEXP_REPLACE(destination_table.table_id, '^activity_', '') AS arm,
  CAST(NULL AS STRING) AS variant, CAST(NULL AS STRING) AS batch,
  job_id, creation_time, total_bytes_processed, total_bytes_billed, total_slot_ms,
  TIMESTAMP_DIFF(end_time, start_time, MILLISECOND) AS duration_ms,
  dml_statistics.inserted_row_count, dml_statistics.updated_row_count, dml_statistics.deleted_row_count, query
FROM \`$REGION\`.INFORMATION_SCHEMA.$JOBS_VIEW
WHERE creation_time > TIMESTAMP '$since' AND statement_type = 'MERGE' AND state = 'DONE' AND error_result IS NULL
  AND destination_table.dataset_id = '$DATASET' AND STARTS_WITH(destination_table.table_id, 'activity_')"
  persist_tables

  for n in $names; do
    format=raw predicate=true records=NULL kafka_bytes=NULL drain_seconds=NULL transfer_cpu_seconds=NULL
    [ "$n" = drain_json ] && format=json
    [ "$n" = a ] && predicate=false
    # shellcheck disable=SC1090
    [ -f "$LOCAL/$n.txt" ] && source "$LOCAL/$n.txt"
    rows="$rows$sep('$RUN_ID', '$n', '$format', $predicate, $records, $kafka_bytes, $drain_seconds, $transfer_cpu_seconds,
  $(flush_values "$n"), '$(cat "$LOCAL/reader.sha" 2>/dev/null || echo unknown)', '$(cat "$LOCAL/transfer.sha" 2>/dev/null || echo unknown)', CURRENT_TIMESTAMP())"
    sep=", "
  done
  q --label=kind:setup "DELETE FROM \`$RDS.local_runs\` WHERE run_id = '$RUN_ID';
INSERT INTO \`$RDS.local_runs\` VALUES $rows" >/dev/null

  {
    echo "reader $(cat "$LOCAL/reader.sha" 2>/dev/null || echo unknown), transfer $(cat "$LOCAL/transfer.sha" 2>/dev/null || echo unknown), run $RUN_ID"
    echo "steady arms (a: no predicate, b: predicate): $BATCHES batches of 500 changes, flush every ${FLUSH}s, raw records"
    echo "drain: $(tr '\n' ' ' <"$LOCAL/drain_counts" 2>/dev/null)rows changed in Postgres, predicate on, bufferRows $DRAIN_BUFFER"
    echo
    echo "Runs ($RDS.local_runs):"
    q --format=pretty "SELECT name, format, predicate, records, ROUND(kafka_bytes / 1e6, 1) AS kafka_mb, drain_seconds,
  ROUND(SAFE_DIVIDE(records, drain_seconds)) AS records_per_s, transfer_cpu_seconds,
  ROUND(SAFE_DIVIDE(transfer_cpu_seconds * 1e6, records), 1) AS cpu_us_per_record, flushes, flush_p50_ms, flush_p95_ms, flush_mean_ms
FROM \`$RDS.local_runs\` WHERE run_id = '$RUN_ID' ORDER BY name"
    echo
    echo "Transfer's MERGE jobs ($RDS.merges, source = 'local'):"
    q --format=pretty "SELECT arm, COUNT(*) AS merges,
  ROUND(APPROX_QUANTILES(total_bytes_processed, 2)[OFFSET(1)] / POW(10, 9), 3) AS median_gb_processed,
  ROUND(APPROX_QUANTILES(total_slot_ms, 2)[OFFSET(1)] / 1000, 1) AS median_slot_s,
  ROUND(APPROX_QUANTILES(duration_ms, 2)[OFFSET(1)] / 1000, 1) AS median_duration_s,
  ROUND(SUM(duration_ms) / 1000, 1) AS total_duration_s,
  ROUND(SUM(total_bytes_billed) / POW(10, 9), 1) AS total_gb_billed,
  ROUND(AVG(total_bytes_billed) * 288 / POW(2, 40) * 6.25, 2) AS usd_per_day_5min
FROM \`$RDS.merges\` WHERE run_id = '$RUN_ID' AND source = 'local' GROUP BY 1 ORDER BY 1"
    echo
    echo "Row checks: steady arms expect $expected rows and $((BATCHES * 150)) updated; drain tables expect $drain_expected rows,"
    echo "$(cat "$LOCAL/drain_updated" 2>/dev/null) drained, and the same fingerprint for raw and JSON."
    local checks="" union=""
    for n in $names; do
      checks="$checks$union SELECT '$n' AS arm, COUNT(*) AS row_count, COUNTIF(STARTS_WITH(status, 'updated_')) AS updated,
  COUNTIF(status = 'drained') AS drained, BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t))) AS fingerprint FROM \`$DS.activity_$n\` t"
      union=" UNION ALL"
    done
    q --label=kind:verify --format=pretty "$checks ORDER BY arm"
  } | tee "$LOCAL/summary.txt"
}

step_down() {
  dc down -v
}

steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(up build seed arm_a arm_b drain report_local down)
log "local run $RUN_ID, anchor $ANCHOR, dataset $DS"
for s in "${steps[@]}"; do
  log "step $s"
  "step_$s"
done
