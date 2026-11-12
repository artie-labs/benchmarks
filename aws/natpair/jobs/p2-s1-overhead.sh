#!/bin/bash
# Phase 2, scenario 1 (and 7 on the large): what pacing costs when nothing contends. TCP uploads as fast as 32 flows
# go, and 64-byte UDP at UDP_HI, pacing off then on, 3 rounds. Each NAT records BPF run time per program.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for p in off on; do
    ./run.sh "$t-p2-s1-tcp-$p-$k" MODE=up PROCS=1 STREAMS=16 DURATION=60 PACING=$p
    ./run.sh "$t-p2-s1-udp-$p-$k" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=$UDP_HI DURATION=60 PACING=$p
  done
done
