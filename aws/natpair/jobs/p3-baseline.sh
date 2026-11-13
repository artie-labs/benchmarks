#!/bin/bash
# Phase 3 baseline, pacing off: what a CPU-saturated owner does to the pair before control-plane priority.
# 1. Interrupt spreading after takeovers: TCP uploads at 2 Gbps with `natpair maintenance` on the owner 20 s in,
#    3 rounds, alternating owners. Each run's irq.txt shows which CPU each queue's interrupt goes to on both NATs.
# 2. TCP uploads as fast as 32 flows go, 60 s, and TCP with 88-byte segments from 64 flows, 90 s, 3 rounds each,
#    counting takeovers. The first shows the throughput with the shared ENI's interrupts spread.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for nat in "$NAT_A" "$NAT_B"; do on "$nat" 60 "natpair pacing-off" > /dev/null; done
for k in 1 2 3; do
  wait_standby_ready || exit 1
  ./run.sh "$t-p3-takeover-$k" MODE=up PROCS=1 STREAMS=16 RATE=62.5M DURATION=60 HANDOVER_AT=20 PING=1 PACING=off
done
wait_standby_ready
for k in 1 2 3; do
  ./run.sh "$t-p3-tcp-$k" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1 PACING=off
  ./run.sh "$t-p3-overload88-$k" MODE=up PROCS=2 STREAMS=16 MSS=88 DURATION=90 PING=1 PACING=off
done
