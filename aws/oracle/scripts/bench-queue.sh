#!/bin/bash
# Runs bench jobs one at a time, oldest first, from s3://$BUCKET/images/$QUEUE/ (the box can read images/ and write
# results/ only, so jobs are never deleted: /root/$QUEUE/taken.txt lists the ones already run). A job is a bash script
# named <UTC timestamp>-<name>.sh (see submit-job.sh). It runs in /opt/oracle-bench with BUCKET set, after
# oracle-bench-sync. Output: results/$QUEUE/<name>.log. History: results/$QUEUE/history.txt.
set -uo pipefail
BUCKET=benchmark-oracle-3debc8cdf0814272bcfd41b84c
# QUEUE names this box's queue: "queue" on the main box, "queue-replay" on the replay box.
QUEUE=${QUEUE:-queue}
mkdir -p /root/$QUEUE /opt/oracle-bench/results/$QUEUE
touch /root/$QUEUE/taken.txt
while true; do
  job=$(aws s3 ls "s3://$BUCKET/images/$QUEUE/" 2>/dev/null | awk '{print $4}' | grep '\.sh$' | sort | grep -vxF -f /root/$QUEUE/taken.txt | head -1)
  if [[ -z "$job" ]]; then sleep 20; continue; fi
  aws s3 cp "s3://$BUCKET/images/$QUEUE/$job" "/root/$QUEUE/$job" --only-show-errors || { sleep 10; continue; }
  echo "$job" >> /root/$QUEUE/taken.txt
  name=${job%.sh}
  log=/opt/oracle-bench/results/$QUEUE/$name.log
  echo "$(date -u +%FT%TZ) START $job" >> /opt/oracle-bench/results/$QUEUE/history.txt
  aws s3 cp /opt/oracle-bench/results/$QUEUE/history.txt "s3://$BUCKET/results/$QUEUE/history.txt" --only-show-errors || true
  oracle-bench-sync >/dev/null 2>&1 || true
  (cd /opt/oracle-bench && BUCKET=$BUCKET bash "/root/$QUEUE/$job") > "$log" 2>&1
  rc=$?
  echo "$(date -u +%FT%TZ) END $job rc=$rc" | tee -a "$log" >> /opt/oracle-bench/results/$QUEUE/history.txt
  aws s3 sync /opt/oracle-bench/results/ "s3://$BUCKET/results/" --only-show-errors || true
done
