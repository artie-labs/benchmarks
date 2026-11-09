#!/bin/bash
# A/B of Reader builds on 2M-change drains: PR 2 (messages built on other goroutines while mining continues, bd19878c)
# vs PR 3 (single-session speedups, 1c9f57b4), and optionally PR 3 plus one fewer build goroutine than GOMAXPROCS
# (00ec0211, an experiment kept off the PR). All images are built from clean commits with go1.27.3, CGO_ENABLED=0,
# GOAMD64=v1 and -trimpath, the same way as PR 2's.
#
# Upload first:
#   aws s3 cp /tmp/ss-build/reader-single-1c9f57b4-amd64.tar.gz s3://$BUCKET/images/
#   aws s3 cp /tmp/ss-build/reader-buildcap-00ec0211-amd64.tar.gz s3://$BUCKET/images/   # only with WITH_CAP=1
# reader-pipeline-bd19878c.tar.gz is already there from the PR 2 A/B.
#
# WITH_CAP=1 adds the third image to each round. Results land in results/ and are synced to s3://$BUCKET/results/.
set -euo pipefail
cd /opt/oracle-bench
BUCKET=benchmark-oracle-3debc8cdf0814272bcfd41b84c
A=oracle-bench/reader:pipeline-bd19878c
B=oracle-ss/reader:single-1c9f57b4-amd64
C=oracle-ss/reader:buildcap-00ec0211-amd64
files="reader-pipeline-bd19878c reader-single-1c9f57b4-amd64"
images="$A $B"
if [[ "${WITH_CAP:-0}" == 1 ]]; then
  files="$files reader-buildcap-00ec0211-amd64"
  images="$images $C"
fi
for f in $files; do aws s3 cp "s3://$BUCKET/images/$f.tar.gz" - | gunzip | docker load; done
./bench.py setup --reset --seed-rows 10000000
READER_IMAGE=$A ./bench.py prime

# Rotate which build goes first in each round, so drift over the session hits each evenly. One-second polls keep the
# poll interval small next to a drain that may take under 30 s.
read -r -a order <<< "$images"
for round in 1 2 3 4 5; do
  for image in "${order[@]}"; do
    READER_IMAGE=$image ./bench.py drain --poll-seconds 1 > "/tmp/ab-$round-${image##*:}.log" 2>&1
  done
  order=("${order[@]:1}" "${order[0]}")
done

# Not reported: a 10 s execution trace of PR 2 and of PR 3 from Reader's first Kafka write, for the mining goroutine's
# breakdown (running, waiting on the network, waiting for a P). No CPU profile runs during them, unlike the PR 2 A/B's
# trace. Give up on a trace after 2 minutes rather than hang if the drain fails before its first write.
trace_drain() {
  local image=$1 name=$2
  READER_IMAGE=$image ./bench.py drain --poll-seconds 1 > "/tmp/ab-trace-$name.log" 2>&1 &
  for _ in $(seq 600); do
    if curl -s http://127.0.0.1:8081/debug/pprof/goroutine?debug=1 2>/dev/null | grep -q "BatchWriter).Write"; then
      curl -s -o "results/$name.trace" "http://127.0.0.1:8081/debug/pprof/trace?seconds=10"
      break
    fi
    sleep 0.2
  done
  wait
}
trace_drain "$A" pipeline-bd19878c-notprofiled
trace_drain "$B" single-1c9f57b4

# Not reported: one profiled PR 3 drain, a 30 s CPU profile and a heap profile.
READER_IMAGE=$B ./bench.py drain --profile-seconds 30 > /tmp/ab-profile.log 2>&1

aws s3 sync results/ "s3://$BUCKET/results/" --only-show-errors
echo AB-DONE
