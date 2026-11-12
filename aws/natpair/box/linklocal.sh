#!/bin/bash
# Runs on one NAT: trips linklocal_allowance_exceeded with linklocal.py while enapoll samples the NAT's own ENI every
# 10 ms (or the given poll interval), then uploads a run directory that analyze.py reads like any other run (this NAT as the owner).
# Usage: env BUCKET=<bucket> AWS_REGION=<region> RUN=<run id> bash linklocal.sh <rate> <on s> <off s> <cycles> [poll]
set -euo pipefail
rate=$1 on=$2 off=$3 cycles=$4 poll=${5:-10ms}
dir=/tmp/natpair-bench/$RUN
mkdir -p "$dir"
cd "$dir"
export AWS_DEFAULT_REGION=$AWS_REGION
token=$(curl -s -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
imds() { curl -s -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"; }
instance=$(imds instance-id)
mac=$(cat /sys/class/net/ens5/address)
echo "ens5 $(imds "network/interfaces/macs/$mac/interface-id")" > interfaces-start.txt
aws s3 cp --only-show-errors "s3://$BUCKET/box/bin/enapoll" /tmp/natpair-bench/enapoll
chmod +x /tmp/natpair-bench/enapoll
aws s3 cp --only-show-errors "s3://$BUCKET/box/linklocal.py" ./linklocal.py
duration=$(((on + off) * cycles))
start=$(date +%s)
/tmp/natpair-bench/enapoll -i ens5 -interval "$poll" -duration "$((duration + 8))s" -out enapoll.csv -cpu cpu.csv -procs natpair &
sleep "$((start + 3 - $(date +%s)))"
python3 -I linklocal.py --rate "$rate" --on "$on" --off "$off" --cycles "$cycles" --edges edges.txt
wait
gzip -f enapoll.csv
journalctl -u natpair --since "@$start" -o short-iso-precise --no-pager > journal.txt
python3 -I -c 'import json, sys; print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:]), indent=1))' \
  run="$RUN" name=linklocal owner="$instance" standby= generators= receiver_ip= shared_eni= shared_private_ip= \
  start="$start" load_at="$((start + 3))" DURATION="$duration" PRE=3 POST=5 PATTERN=onoff ON="$on" OFF="$off" \
  MODE=linklocal RATE="$rate" POLL="$poll" > ../meta-$RUN.json
aws s3 cp --only-show-errors ../meta-$RUN.json "s3://$BUCKET/runs/$RUN/meta.json"
aws s3 cp --only-show-errors --recursive . "s3://$BUCKET/runs/$RUN/$instance/"
echo "uploaded $RUN"
