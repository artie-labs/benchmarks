#!/bin/bash
# Kernel 6.18 investigation: TCP as fast as 32 flows go, as in rc-kernel-ab, with the owner profiled by box/prof.sh
# during the load and again idle. KERNEL names the kernel in run names. EXTRA=1 adds two runs that test causes:
# enapoll reading the NATs' ENA counters once a second instead of every 10 ms, and threaded NAPI on the owner's
# interfaces, which moves receive processing from softirq into threads the scheduler shares the CPU with.
KERNEL=${KERNEL:-k}
EXTRA=${EXTRA:-0}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
label=$(date -u +%Y%m%dT%H%M%SZ)-$t-$KERNEL
prof_cmd() {
  echo "aws s3 cp --only-show-errors --region $AWS_REGION s3://$BUCKET/box/prof.sh /tmp/natpair-bench-prof.sh && env AWS_REGION=$AWS_REGION BUCKET=$BUCKET LABEL=$label PHASE=$1 AT=$2 REPORT_DELAY=${3:-0} bash /tmp/natpair-bench-prof.sh"
}
for nat in "$NAT_A" "$NAT_B"; do on "$nat" 600 "$(prof_cmd setup 0)" > /dev/null || echo "prof setup failed on $nat"; done

wait_standby_ready || exit 1
./run.sh "$t-$KERNEL-a-tcp" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1

wait_standby_ready || exit 1
owner=$(owner_nat)
# run.sh starts the load about 26 s after it begins, so this profiles from about 19 s into the 90 s load to 65 s.
id=$(ssm_send "$owner" 600 "$(prof_cmd load "$(($(date +%s) + 45))" 80)")
./run.sh "$t-$KERNEL-a-prof" MODE=up PROCS=1 STREAMS=16 DURATION=90 PING=1
ssm_wait "$id" "$owner" > /dev/null || echo "load profile failed on $owner"
on "$owner" 600 "$(prof_cmd idle "$(($(date +%s) + 5))")" > /dev/null || echo "idle profile failed on $owner"
echo "profiles in s3://$BUCKET/runs/prof/$label/"

if [[ $EXTRA == 1 ]]; then
  wait_standby_ready || exit 1
  ./run.sh "$t-$KERNEL-a-poll1s" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1 POLL=1s
  wait_standby_ready || exit 1
  owner=$(owner_nat)
  on "$owner" 60 'for f in /sys/class/net/ens*/threaded; do echo 1 > $f; done; grep -H . /sys/class/net/ens*/threaded'
  ./run.sh "$t-$KERNEL-a-threaded" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1
  on "$owner" 60 'for f in /sys/class/net/ens*/threaded; do echo 0 > $f; done; grep -H . /sys/class/net/ens*/threaded'
fi
