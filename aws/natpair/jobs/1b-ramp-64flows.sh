#!/bin/bash
# Phase 1, measurement 2: the packet-rate ramp with 64 UDP flows instead of 16. The NIC spreads flows over its
# queues, one per vCPU, by hash. With 16 flows one queue of a c7gn.large's two can take most of them, so this shows
# what both CPUs forward together. 800k, 1M and 1.2M packets a second in total, then unlimited, 2 rounds.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2; do
  for rate in 6.4M 8M 9.6M 0; do
    ./run.sh "$t-udp-ramp64-$rate-$k" MODE=udp LEN=64 PROCS=1 STREAMS=32 RATE=$rate DURATION=30
  done
done
