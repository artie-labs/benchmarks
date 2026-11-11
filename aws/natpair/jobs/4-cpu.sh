#!/bin/bash
# Phase 1, measurement 3: the NAT's CPU at fixed rates, below its limits. TCP uploads of full-size packets at 0.5, 1,
# 2 and 3 Gbps in total, and UDP 64-byte payloads at 100k, 200k and 300k packets a second. 16 flows, 3 rounds.
# The NATs are sampled once a second here: every 10 ms costs about 5% of a c7gn.medium's only CPU. The two idle runs
# measure that cost.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
./run.sh "$t-cpu-idle-poll1s" MODE=none DURATION=30 POLL=1s
./run.sh "$t-cpu-idle-poll10ms" MODE=none DURATION=30 POLL=10ms
for k in 1 2 3; do
  for rate in 31.25M 62.5M 125M 187.5M; do
    ./run.sh "$t-cpu-tcp-$rate-$k" MODE=up PROCS=1 STREAMS=8 RATE=$rate DURATION=30 POLL=1s
  done
  for rate in 3.2M 6.4M 9.6M; do
    ./run.sh "$t-cpu-udp-$rate-$k" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=$rate DURATION=30 POLL=1s
  done
done
