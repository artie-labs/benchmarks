#!/usr/bin/env bash
# BigQuery MERGE partition pruning benchmark. See README.md.
#
#   PROJECT=my-project ./run.sh                 # every step
#   PROJECT=my-project ./run.sh h2h report      # selected steps
#   PROJECT=my-project ./run.sh cleanup         # drop the dataset
set -euo pipefail

: "${PROJECT:?set PROJECT to the GCP project to run in}"
DATASET="${DATASET:-bq_merge_partition_bench}"
LOCATION="${LOCATION:-US}"
RPD="${RPD:-100000}"   # rows per day; ~500 B each, so 100k rows is ~50 MB per daily partition
REPS="${REPS:-3}"
H2H_REPS="${H2H_REPS:-5}"
SEQ_BATCHES=24         # two hours of five-minute flushes
# Batches update and delete up to 3,600 existing rows per day.
[ "$RPD" -ge 10000 ] || { echo "RPD must be at least 10000" >&2; exit 1; }

DS="$PROJECT.$DATASET"
# Results live in their own dataset, which cleanup keeps.
RESULTS_DATASET="${RESULTS_DATASET:-${DATASET}_results}"
RDS="$PROJECT.$RESULTS_DATASET"
# Reports read merges from this view. JOBS_BY_USER needs bigquery.jobs.list (BigQuery User) and sees only the bq
# account's jobs; JOBS_BY_PROJECT needs bigquery.jobs.listAll and sees every account's jobs.
JOBS_VIEW="${JOBS_VIEW:-JOBS_BY_USER}"
REGION="region-$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]')"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/results"
mkdir -p "$OUT"

# The anchor date and run ID are fixed on first use, so steps can be rerun separately.
# ANCHOR and RUN_ID can be set, so jobs on different machines share one run.
[ -f "$OUT/anchor" ] || echo "${ANCHOR:-$(date -u +%F)}" >"$OUT/anchor"
[ -f "$OUT/run_id" ] || echo "${RUN_ID:-$(date -u +%Y%m%d%H%M)}" >"$OUT/run_id"
ANCHOR="$(cat "$OUT/anchor")"
RUN_ID="$(cat "$OUT/run_id")"

# Every statement is also appended to results/queries.sql, which shows exactly how the data was generated and merged.
q() {
  printf -- '-- %s\n%s\n\n' "$(date -u +%FT%TZ)" "${@: -1}" >>"$OUT/queries.sql"
  # bq prints errors to stdout, which callers often discard, so a failure's output goes to stderr.
  local out
  if out=$(bq --quiet --project_id="$PROJECT" --location="$LOCATION" query --use_legacy_sql=false --nouse_cache \
    --label=bench:bq-merge-partition --label="run:$RUN_ID" "$@"); then
    printf '%s\n' "$out"
  else
    printf 'bq query failed:\n%s\n' "$out" >&2
    return 1
  fi
}

log() { echo "[$(date -u +%T)] $*"; }

# Partition expression, DATE_TRUNC unit and partition-start format for each grain Artie Transfer supports.
partition_expr() {
  case "$1" in
    hourly) echo "TIMESTAMP_TRUNC(created_at, HOUR)" ;;
    daily) echo "DATE(created_at)" ;;
    monthly) echo "TIMESTAMP_TRUNC(created_at, MONTH)" ;;
    yearly) echo "TIMESTAMP_TRUNC(created_at, YEAR)" ;;
  esac
}
time_unit() {
  case "$1" in hourly) echo HOUR ;; daily) echo DAY ;; monthly) echo MONTH ;; yearly) echo YEAR ;; esac
}
start_format() {
  case "$1" in
    hourly) echo "%F %H:00:00" ;; daily) echo "%F" ;; monthly) echo "%Y-%m-01" ;; yearly) echo "%Y-01-01" ;;
  esac
}

# Rows are deterministic in (date, n), so batches can update and delete existing rows without reading the target.
# created_at spreads n evenly over the day; n above RPD wraps around, which is how inserts get new UUIDs.
rows() { # dates_array lo hi status
  echo "SELECT TO_HEX(MD5(FORMAT('%t-%d', d, n))) AS uuid,
  TIMESTAMP_ADD(TIMESTAMP(d), INTERVAL DIV(MOD(n - 1, $RPD) * 86400, $RPD) SECOND) AS created_at,
  '$4' AS status, TO_JSON(STRUCT(n AS seq, '$4' AS status, REPEAT('x', 400) AS note)) AS payload
FROM UNNEST($1) d, UNNEST(GENERATE_ARRAY($2, $3)) n"
}
day() { echo "[DATE_SUB(DATE '$ANCHOR', INTERVAL $1 DAY)]"; }

generate() { # name days grain [cluster]
  local cluster=""
  [ "${4:-}" = cluster ] && cluster="CLUSTER BY uuid"
  q --label=kind:setup "CREATE OR REPLACE TABLE \`$DS.$1\`
(uuid STRING NOT NULL, created_at TIMESTAMP, status STRING, payload JSON)
PARTITION BY $(partition_expr "$3") $cluster
AS $(rows "GENERATE_DATE_ARRAY(DATE_SUB(DATE '$ANCHOR', INTERVAL $2 - 1 DAY), DATE '$ANCHOR')" 1 "$RPD" created)" >/dev/null
  log "generated $1"
}

# A five-minute CDC batch just after midnight UTC: 300 inserts at 01:00 today, 150 updates to rows created
# in today's first hour, 50 deletes of rows created yesterday at 23:00. Two daily partitions, three hourly.
recent_batch() { # k
  local k=$1 ins=$((RPD * ($1 + 2) + RPD / 24 + 34))
  echo "SELECT *, false AS __artie_delete FROM ($(rows "$(day 0)" "$ins" $((ins + 299)) "inserted_$k"))
UNION ALL SELECT *, false FROM ($(rows "$(day 0)" $((k * 150 + 1)) $((k * 150 + 150)) "updated_$k"))
UNION ALL SELECT *, true FROM ($(rows "$(day 1)" $((RPD - (k + 1) * 50 + 1)) $((RPD - k * 50)) "deleted_$k"))"
}

# ~500 updates spread evenly over n distinct days of a table with the given number of days.
spread_batch() { # n days
  echo "SELECT *, false AS __artie_delete FROM ($(rows "ARRAY(SELECT DATE_SUB(DATE '$ANCHOR', INTERVAL DIV(i * $2, $1) DAY) FROM UNNEST(GENERATE_ARRAY(0, $1 - 1)) i)" 1 $(((500 + $1 - 1) / $1)) "spread_$1"))"
}

# Sequence batch k: a recent batch, plus historical corrections every sixth batch and a NULL created_at in batch 11.
seq_batch() { # k
  local k=$1 sql
  sql="$(recent_batch "$k")"
  if [ $((k % 6)) -eq 5 ]; then
    sql="$sql
UNION ALL SELECT *, false FROM ($(rows "[DATE_SUB(DATE '$ANCHOR', INTERVAL 400 DAY), DATE_SUB(DATE '$ANCHOR', INTERVAL 900 DAY)]" $((k * 5 + 1)) $((k * 5 + 5)) "corrected_$k"))"
  fi
  if [ "$k" -eq 11 ]; then
    sql="$sql
UNION ALL SELECT TO_HEX(MD5('null-created-at')), CAST(NULL AS TIMESTAMP), 'inserted_11', JSON '{}', false"
  fi
  echo "$sql"
}

stage() { # batch_sql
  q --label=kind:setup "CREATE OR REPLACE TABLE \`$DS.stg\` AS $1" >/dev/null
}

clone() { # source target
  q --label=kind:setup "DROP TABLE IF EXISTS \`$DS.$2\`; CREATE TABLE \`$DS.$2\` CLONE \`$DS.$1\`" >/dev/null
}

# The MERGE statement Artie Transfer generates for BigQuery, with its partition predicate when arm is b.
# Arm b computes the distinct partition starts from the staged rows, as transfer does in memory, and skips the
# predicate if any row has a NULL partition value.
merge() { # target grain arm scenario tbl variant [batch]
  local target=$1 grain=$2 arm=$3 pred="" raw sep="','"
  if [ "$arm" = b ]; then
    raw="$(q --label=kind:predicate --format=csv "SELECT IF(COUNTIF(created_at IS NULL) > 0, 'NULL',
  STRING_AGG(DISTINCT FORMAT_TIMESTAMP('$(start_format "$grain")', created_at, 'UTC'), '|')) FROM \`$DS.stg\`" | tail -n1)"
    if [ "$raw" != NULL ]; then
      pred=" AND DATE_TRUNC(tgt.\`created_at\`, $(time_unit "$grain")) IN ('${raw//|/$sep}')"
    fi
  fi
  q --label=kind:merge --label="scenario:$4" --label="tbl:$5" --label="arm:$arm" --label="variant:$6" --label="batch:${7:-0}" "
MERGE INTO \`$DS.$target\` tgt USING \`$DS.stg\` AS stg ON tgt.\`uuid\` = stg.\`uuid\`$pred
WHEN MATCHED AND stg.\`__artie_delete\` THEN DELETE
WHEN MATCHED AND IFNULL(stg.\`__artie_delete\`, false) = false THEN UPDATE SET \`uuid\`=stg.\`uuid\`,\`created_at\`=stg.\`created_at\`,\`status\`=stg.\`status\`,\`payload\`=stg.\`payload\`
WHEN NOT MATCHED AND IFNULL(stg.\`__artie_delete\`, false) = false THEN INSERT (\`uuid\`,\`created_at\`,\`status\`,\`payload\`) VALUES (stg.\`uuid\`,stg.\`created_at\`,stg.\`status\`,stg.\`payload\`);" >/dev/null
}

# Clone the table, then merge the staged batch into the clone, so every run starts from the same data.
run_once() { # table grain arm scenario variant
  clone "$1" work
  merge work "$2" "$3" "$4" "$1" "$5"
}

step_setup() {
  ensure_results
  bq --project_id="$PROJECT" show "$PROJECT:$DATASET" >/dev/null 2>&1 ||
    bq --project_id="$PROJECT" --location="$LOCATION" mk --dataset "$PROJECT:$DATASET"
  local pids=()
  generate daily_1095 1095 daily & pids+=($!)
  generate daily_1095_clustered 1095 daily cluster & pids+=($!)
  generate daily_365 365 daily & pids+=($!)
  generate daily_180 180 daily & pids+=($!)
  generate daily_150 150 daily & pids+=($!)
  generate daily_30 30 daily & pids+=($!)
  # Hourly stays under BigQuery's 4,000 partitions per job.
  generate hourly_150 150 hourly & pids+=($!)
  generate monthly_1095 1095 monthly & pids+=($!)
  generate yearly_1095 1095 yearly & pids+=($!)
  for p in "${pids[@]}"; do wait "$p"; done
}

# No predicate, Artie's predicate, and no predicate on a table clustered by uuid.
step_h2h() {
  stage "$(recent_batch 0)"
  for i in $(seq "$H2H_REPS"); do
    run_once daily_1095 daily a h2h recent
    run_once daily_1095 daily b h2h recent
    run_once daily_1095_clustered daily c h2h recent
    log "h2h rep $i"
  done
}

# Bytes processed against table history.
step_scaling() {
  stage "$(recent_batch 0)"
  for days in 30 180 365 1095; do
    for i in $(seq "$REPS"); do
      run_once "daily_$days" daily a scaling recent
      run_once "daily_$days" daily b scaling recent
    done
    log "scaling $days days"
  done
}

# How many partitions one batch touches.
step_spread() {
  for n in 1 2 7 30 365; do
    stage "$(spread_batch "$n" 1095)"
    for i in $(seq "$REPS"); do run_once daily_1095 daily b spread "n$n"; done
    log "spread $n partitions"
  done
}

# Partition grain.
step_grains() {
  stage "$(recent_batch 0)"
  for t in hourly_150:hourly daily_150:daily monthly_1095:monthly yearly_1095:yearly; do
    for i in $(seq "$REPS"); do
      run_once "${t%%:*}" "${t##*:}" a grains recent
      run_once "${t%%:*}" "${t##*:}" b grains recent
    done
    log "grains ${t%%:*}"
  done
}

# Two hours of flushes per arm, on persistent clones that step_verify compares afterwards.
step_sequence() {
  clone daily_1095 seq_a
  clone daily_1095 seq_b
  for k in $(seq 0 $((SEQ_BATCHES - 1))); do
    stage "$(seq_batch "$k")"
    merge seq_a daily a sequence daily_1095 seq "$k"
    merge seq_b daily b sequence daily_1095 seq "$k"
    log "sequence batch $k"
  done
}

# Both arms must end with identical rows, and the expected count.
step_verify() {
  local expected=$((1095 * RPD + SEQ_BATCHES * 300 - SEQ_BATCHES * 50 + 1))
  q --label=kind:verify --format=csv "
SELECT 'seq_a' AS tbl, COUNT(*) AS row_count, BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t))) AS fingerprint FROM \`$DS.seq_a\` t
UNION ALL
SELECT 'seq_b', COUNT(*), BIT_XOR(FARM_FINGERPRINT(TO_JSON_STRING(t))) FROM \`$DS.seq_b\` t" | tee "$OUT/verify.csv"
  local distinct
  distinct="$(tail -n +2 "$OUT/verify.csv" | cut -d, -f2,3 | sort -u)"
  if [ "$(echo "$distinct" | wc -l | tr -d ' ')" = 1 ] && [ "${distinct%%,*}" = "$expected" ]; then
    log "verify ok: both arms have $expected rows and the same fingerprint"
  else
    log "verify FAILED: expected $expected identical rows in both arms"
    return 1
  fi
}

ensure_results() {
  bq --project_id="$PROJECT" show "$PROJECT:$RESULTS_DATASET" >/dev/null 2>&1 ||
    bq --project_id="$PROJECT" --location="$LOCATION" mk --dataset "$PROJECT:$RESULTS_DATASET"
  q --label=kind:setup "
CREATE TABLE IF NOT EXISTS \`$RDS.merges\` (
  run_id STRING, source STRING, scenario STRING, tbl STRING, arm STRING, variant STRING, batch STRING,
  job_id STRING, creation_time TIMESTAMP, total_bytes_processed INT64, total_bytes_billed INT64, total_slot_ms INT64,
  duration_ms INT64, inserted_row_count INT64, updated_row_count INT64, deleted_row_count INT64, query STRING);
CREATE TABLE IF NOT EXISTS \`$RDS.tables\` (
  run_id STRING, table_name STRING, partitions INT64, row_count INT64, logical_bytes INT64, recorded_at TIMESTAMP);
CREATE TABLE IF NOT EXISTS \`$RDS.local_runs\` (
  run_id STRING, name STRING, format STRING, predicate BOOL, records INT64, kafka_bytes INT64, drain_seconds INT64,
  transfer_cpu_seconds FLOAT64, flushes INT64, flush_p50_ms FLOAT64, flush_p95_ms FLOAT64, flush_mean_ms FLOAT64,
  flush_max_ms FLOAT64, reader_sha STRING, transfer_sha STRING, recorded_at TIMESTAMP)" >/dev/null
}

# Adds MERGE jobs to the merges table, once per job. select must return merges' columns in order.
persist_merges() { # select
  q --label=kind:setup "MERGE \`$RDS.merges\` m USING ($1) s ON m.job_id = s.job_id WHEN NOT MATCHED THEN INSERT ROW" >/dev/null
}

persist_tables() {
  q --label=kind:setup "DELETE FROM \`$RDS.tables\` WHERE run_id = '$RUN_ID';
INSERT INTO \`$RDS.tables\`
SELECT '$RUN_ID', table_name, COUNT(*), SUM(total_rows), SUM(total_logical_bytes), CURRENT_TIMESTAMP()
FROM \`$DS\`.INFORMATION_SCHEMA.PARTITIONS WHERE table_name NOT IN ('work', 'stg') GROUP BY table_name" >/dev/null
}

step_report() {
  ensure_results
  persist_merges "SELECT '$RUN_ID' AS run_id, 'sql' AS source,
  (SELECT value FROM UNNEST(labels) WHERE key = 'scenario') AS scenario,
  (SELECT value FROM UNNEST(labels) WHERE key = 'tbl') AS tbl,
  (SELECT value FROM UNNEST(labels) WHERE key = 'arm') AS arm,
  (SELECT value FROM UNNEST(labels) WHERE key = 'variant') AS variant,
  (SELECT value FROM UNNEST(labels) WHERE key = 'batch') AS batch,
  job_id, creation_time, total_bytes_processed, total_bytes_billed, total_slot_ms,
  TIMESTAMP_DIFF(end_time, start_time, MILLISECOND) AS duration_ms,
  dml_statistics.inserted_row_count, dml_statistics.updated_row_count, dml_statistics.deleted_row_count, query
FROM \`$REGION\`.INFORMATION_SCHEMA.$JOBS_VIEW
WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  AND state = 'DONE' AND error_result IS NULL
  AND EXISTS(SELECT 1 FROM UNNEST(labels) WHERE key = 'run' AND value = '$RUN_ID')
  AND EXISTS(SELECT 1 FROM UNNEST(labels) WHERE key = 'kind' AND value = 'merge')"
  persist_tables

  q --format=csv --max_rows=100000 "SELECT * EXCEPT (query) FROM \`$RDS.merges\`
WHERE run_id = '$RUN_ID' AND source = 'sql' ORDER BY creation_time" >"$OUT/merges.csv"

  # usd_per_day_5min: mean bytes billed per merge x 288 merges a day, at \$6.25 per TiB on demand.
  q --format=csv --max_rows=1000 "SELECT scenario, tbl, arm, variant, COUNT(*) AS runs,
  ROUND(APPROX_QUANTILES(total_bytes_processed, 2)[OFFSET(1)] / POW(10, 9), 3) AS median_gb_processed,
  ROUND(APPROX_QUANTILES(total_bytes_billed, 2)[OFFSET(1)] / POW(10, 9), 3) AS median_gb_billed,
  ROUND(APPROX_QUANTILES(total_slot_ms, 2)[OFFSET(1)] / 1000, 1) AS median_slot_s,
  ROUND(APPROX_QUANTILES(duration_ms, 2)[OFFSET(1)] / 1000, 1) AS median_duration_s,
  ROUND(SUM(total_bytes_billed) / POW(10, 9), 1) AS total_gb_billed,
  ROUND(AVG(total_bytes_billed) * 288 / POW(2, 40) * 6.25, 2) AS usd_per_day_5min
FROM \`$RDS.merges\` WHERE run_id = '$RUN_ID' AND source = 'sql'
GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 4, 3" >"$OUT/summary.csv"

  q --format=csv "SELECT table_name, partitions, row_count, ROUND(logical_bytes / POW(10, 9), 1) AS logical_gb
FROM \`$RDS.tables\` WHERE run_id = '$RUN_ID' ORDER BY 1" >"$OUT/tables.csv"

  log "wrote $RDS.merges and $RDS.tables, and $OUT/summary.csv, merges.csv, tables.csv"
  column -s, -t <"$OUT/summary.csv"
}

step_cleanup() {
  bq --project_id="$PROJECT" rm -r -f --dataset "$PROJECT:$DATASET"
}

# local.sh sources this file for its helpers.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(setup h2h scaling spread grains sequence verify report)
log "run $RUN_ID, anchor $ANCHOR, dataset $DS, $RPD rows per day"
for s in "${steps[@]}"; do
  log "step $s"
  "step_$s"
done
