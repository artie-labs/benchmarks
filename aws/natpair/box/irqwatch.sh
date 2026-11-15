#!/bin/bash
# Records where a NAT's network queue interrupts and napi/ receive threads are, every INTERVAL seconds for SECONDS,
# between and during runs, to see what irqbalance does over a long stretch. Uploads to
# s3://$BUCKET/runs/irqwatch/<name>-<instance id>.txt every minute and at the end.
# Usage: irqwatch.sh <name> <seconds> <interval>. BUCKET and AWS_REGION come from the environment.
set -uo pipefail
name=$1 seconds=$2 interval=$3
export AWS_REGION AWS_DEFAULT_REGION=$AWS_REGION
token=$(curl -s -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
instance=$(curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id)
out=/tmp/irqwatch-$name.txt
: > "$out"
# A build swap stops the watch with SIGTERM, so it uploads what it has first.
trap 'aws s3 cp --only-show-errors "$out" "s3://$BUCKET/runs/irqwatch/$name-$instance.txt"; exit 0' TERM
end=$(($(date +%s) + seconds))
next_upload=$(($(date +%s) + 60))
while (($(date +%s) < end)); do
  t=$(date +%s)
  # One line per sample: time, irqbalance state, then queue=CPU for each queue interrupt, then thread=CPU for each
  # napi/ thread (the CPU it last ran on).
  line="$t $(systemctl is-active irqbalance 2> /dev/null)"
  for irq in $(grep -E 'ens[0-9]+-Tx-Rx' /proc/interrupts | cut -d: -f1); do
    line+=" $(grep "^ *$irq:" /proc/interrupts | awk '{print $NF}')=$(cat /proc/irq/$irq/effective_affinity_list 2> /dev/null)"
  done
  for pid in $(pgrep '^napi/'); do
    stat=$(cat /proc/$pid/stat 2> /dev/null) || continue
    comm=${stat#*(}
    comm=${comm%%)*}
    read -r -a f <<< "${stat##*) }"
    line+=" $comm=${f[36]}"
  done
  echo "$line" >> "$out"
  if (($(date +%s) >= next_upload)); then
    aws s3 cp --only-show-errors "$out" "s3://$BUCKET/runs/irqwatch/$name-$instance.txt"
    next_upload=$(($(date +%s) + 60))
  fi
  sleep "$interval"
done
aws s3 cp --only-show-errors "$out" "s3://$BUCKET/runs/irqwatch/$name-$instance.txt"
