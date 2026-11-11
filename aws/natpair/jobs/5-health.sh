#!/bin/bash
# Phase 1, measurement 5: a handover while AWS drops the owner's traffic. TCP uploads at TCP_CAP after the burst is
# spent, `natpair maintenance` on the owner 30 s in, 100 pings a second through the NAT, receiver counters every
# 10 ms. After each run, `natpair resume` on the old owner, then wait for it to be ready. 3 rounds.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  wait_standby_ready || exit 1
  ./run.sh "$t-handover-$k" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=90 HANDOVER_AT=30 PING=1 RPOLL=10ms
done
wait_standby_ready
