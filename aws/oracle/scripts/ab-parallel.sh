#!/bin/bash
# A/B of Reader on 4M-change drains (about 2.1 GB of redo in 3 archived logs at --redo-mb 1024): PR 3 (single-session
# efficiency, 1c9f57b4) against PR 4 (several LogMiner sessions over a backlog of archived logs, a3d95842, stacked on
# 1c9f57b4) with streamingSettings.logMinerSessions at 1, 2, 3 and 4. logMinerSessions=1 is the control: it runs PR 3's
# single-session path and should match PR 3. PR 3's image ignores the key. Both images are built from clean commits with
# go1.27.3, CGO_ENABLED=0, GOAMD64=v1 and -trimpath. Upload /tmp/plm-build/reader-parallel-a3d95842.tar.gz to
# s3://$BUCKET/images/ first; reader-single-1c9f57b4-amd64.tar.gz is there from the PR 3 A/B. Run it only once
# `systemctl is-active ab-single` reports inactive.
#
# Usage: ab-parallel.sh [rounds] [variants]. Defaults: 5 rounds of "pr3 s1 s3", then one round of "s2 s4". A variant is pr3
# or s<N> (PR 4 with N sessions). With 3 archived logs, s4 mines no more at once than s3. Each round runs the variants in a rotated order, so drift over the session hits each.
set -euo pipefail
while systemctl is-active --quiet ab-single-r5; do sleep 30; done
cd /opt/oracle-bench
BUCKET=benchmark-oracle-3debc8cdf0814272bcfd41b84c
ROUNDS=${1:-5}
VARIANTS=(${2:-pr3 s1 s3})
for f in reader-single-1c9f57b4-amd64 reader-parallel-a3d95842; do aws s3 cp "s3://$BUCKET/images/$f.tar.gz" - | gunzip | docker load; done
PR3=oracle-ss/reader:single-1c9f57b4-amd64
PR4=oracle-bench/reader:parallel-a3d95842
CHANGES=4000000

# Sets logMinerSessions in Reader's config, which bench.py setup writes as JSON.
set_sessions() {
  python3 - "$1" <<'PY'
import json, sys
path = "state/reader.yaml"
reader = json.load(open(path))
reader["oracle"]["streamingSettings"]["logMinerSessions"] = int(sys.argv[1])
json.dump(reader, open(path, "w"), indent=2)
PY
}

# Runs one drain of variant $1 in round $2, and samples Reader's LogMiner queries running at once every 2 s.
drain() {
  local variant=$1 round=$2 image sessions
  if [[ $variant == pr3 ]]; then image=$PR3; sessions=1; else image=$PR4; sessions=${variant#s}; fi
  set_sessions "$sessions"
  READER_IMAGE=$image ./bench.py drain --changes $CHANGES --poll-seconds 1 > "/tmp/abp-$round-$variant.log" 2>&1
  grep -o "results/drain-[0-9TZ:-]*.json" "/tmp/abp-$round-$variant.log" | tail -1 | sed "s|^|$round $variant |" | tee -a /tmp/abp-index.txt
}

rm -f /tmp/abp-index.txt
# Deletes start at the middle of the seeded ids and each 4M drain deletes 800k, so 18 drains need about 15M rows past it.
./bench.py setup --reset --seed-rows 32000000
set_sessions 1
READER_IMAGE=$PR3 ./bench.py prime
for round in $(seq "$ROUNDS"); do
  n=${#VARIANTS[@]}
  for i in $(seq 0 $((n - 1))); do
    drain "${VARIANTS[$(( (i + round) % n ))]}" "$round"
  done
done
# One round of the other session counts, to see where more sessions stop helping.
if [[ -z ${2:-} ]]; then
  for variant in s2 s4; do drain "$variant" sweep; done
fi

# One profiled candidate drain at 3 sessions, not reported: a 10 s execution trace from Reader's first Kafka write, for the
# per-goroutine breakdown (go tool trace -http, then /goroutines), then a 30 s CPU profile. The goroutine dump shows one
# (*minedWindow).run goroutine per LogMiner session mining ahead, to confirm several sessions mine at once.
set_sessions 3
READER_IMAGE=$PR4 ./bench.py drain --changes $CHANGES --profile-seconds 30 > /tmp/abp-profile.log 2>&1 &
for _ in $(seq 600); do
  if curl -s http://127.0.0.1:8081/debug/pprof/goroutine?debug=1 2>/dev/null | grep -q "BatchWriter).Write"; then
    curl -s -o results/parallel-a3d95842.trace "http://127.0.0.1:8081/debug/pprof/trace?seconds=10"
    curl -s -o results/parallel-a3d95842-goroutines.txt "http://127.0.0.1:8081/debug/pprof/goroutine?debug=1"
    break
  fi
  sleep 0.2
done
wait
set_sessions 1
cp /tmp/abp-index.txt /tmp/abp-*.log results/ 2>/dev/null || true
aws s3 sync results/ "s3://$BUCKET/results/" --only-show-errors
echo AB-DONE
