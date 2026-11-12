#!/bin/bash
# Phase 1, measurement 5: a handover while AWS drops the owner's traffic. TCP uploads at BURST_CAP. A short idle
# refills a few minutes of burst, so `natpair maintenance` runs on the owner 120 s in, once the burst is spent.
# 100 pings a second through the NAT and receiver counters every 10 ms measure the gap. After each run, `natpair
# resume` on the old owner, then wait for it to be ready. 3 rounds.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  wait_standby_ready || exit 1
  ./run.sh "$t-handover-$k" MODE=up PROCS=1 STREAMS=16 RATE=$BURST_CAP DURATION=180 HANDOVER_AT=120 PING=1 RPOLL=10ms
done
wait_standby_ready
