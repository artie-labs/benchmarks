#!/bin/bash
# Phase 1, measurements 1 and 2, right after the burst job, so the bandwidth allowance is at its baseline:
# - counter refresh while AWS drops for bandwidth, sampled every 10 ms: steady, then 4 s on and 1 s off. When load
#   stops, drops stop at once, so counter changes after it show how stale the counters are.
# - the sustained limit per direction: TCP up and down at TCP_CAP, and UDP up and down at UDP_CAP, which also
#   splits packets over both ENIs (down replies leave through the owner's own ENI). 3 interleaved rounds.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  ./run.sh "$t-bwrefresh-steady-$k" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60
  ./run.sh "$t-bwrefresh-onoff-$k" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60 PATTERN=onoff ON=4 OFF=1
  ./run.sh "$t-limit-down-$k" MODE=down PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=90
  ./run.sh "$t-limit-udp-up-$k" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=$UDP_CAP DURATION=60
  ./run.sh "$t-limit-udp-down-$k" MODE=udpdown LEN=64 PROCS=1 STREAMS=8 RATE=$UDP_CAP DURATION=60
done
