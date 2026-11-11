#!/bin/bash
# Runs bench jobs one at a time, oldest first, from s3://$BUCKET/jobs/. A job is a bash script named
# <UTC timestamp>-<name>.sh (see scripts/submit-job.sh). It runs in /opt/natpair-bench after natpair-bench-sync.
# Jobs are never deleted: /root/queue/taken.txt lists the ones already run. Output: results/queue/<job>.log.
# History: results/queue/history.txt. Everything under results/ syncs to s3://$BUCKET/results/ after each job.
set -uo pipefail
. /etc/natpair-bench.env
export AWS_REGION AWS_DEFAULT_REGION=$AWS_REGION
results=/opt/natpair-bench-results
mkdir -p /root/queue "$results/queue"
touch /root/queue/taken.txt
while true; do
  job=$(aws s3 ls "s3://$BUCKET/jobs/" 2>/dev/null | awk '{print $4}' | grep '\.sh$' | sort | grep -vxF -f /root/queue/taken.txt | head -1)
  if [[ -z $job ]]; then
    sleep 15
    continue
  fi
  aws s3 cp --only-show-errors "s3://$BUCKET/jobs/$job" "/root/queue/$job" || { sleep 10; continue; }
  echo "$job" >> /root/queue/taken.txt
  log=$results/queue/${job%.sh}.log
  echo "$(date -u +%FT%TZ) START $job" >> "$results/queue/history.txt"
  aws s3 cp --only-show-errors "$results/queue/history.txt" "s3://$BUCKET/results/queue/history.txt" || true
  natpair-bench-sync > /dev/null 2>&1 || true
  (cd /opt/natpair-bench && RESULTS=$results bash "/root/queue/$job") > "$log" 2>&1
  rc=$?
  echo "$(date -u +%FT%TZ) END $job rc=$rc" | tee -a "$log" >> "$results/queue/history.txt"
  aws s3 sync --only-show-errors "$results/" "s3://$BUCKET/results/" || true
done
