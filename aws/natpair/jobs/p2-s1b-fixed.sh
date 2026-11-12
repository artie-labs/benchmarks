#!/bin/bash
# Phase 2, scenario 1 at fixed rates below every limit: TCP uploads at 2 Gbps (32 flows at 62.5 Mbit/s) and 64-byte
# UDP at 200k packets a second, pacing off then on, 3 rounds. Shows what pacing costs in throughput and CPU when
# neither pacing nor AWS should hold anything back. NATs sampled once a second.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for p in off on; do
    ./run.sh "$t-p2-s1b-tcp2g-$p-$k" MODE=up PROCS=1 STREAMS=16 RATE=62.5M DURATION=45 POLL=1s PACING=$p
    ./run.sh "$t-p2-s1b-udp200k-$p-$k" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=6.4M DURATION=45 POLL=1s PACING=$p
  done
done
