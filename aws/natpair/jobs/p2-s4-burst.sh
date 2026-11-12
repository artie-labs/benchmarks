#!/bin/bash
# Phase 2, scenario 4 (c7gn.medium): the burst cliff. TCP uploads at 6 Gbps, which keeps the CPU under the 80% where
# the pacing build cuts its CPU cap. First spend the burst allowance with pacing off. Then reset the pacing caps and
# run 3 rounds of: 2 idle minutes, which refill about a minute of burst, and 240 s at 6 Gbps, pacing off then on,
# so each run crosses the cliff. Drops around it and how fast the cap follows down come from the 10 ms samples.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
rate=187M
./run.sh "$t-p2-s4-spend" MODE=up PROCS=1 STREAMS=16 RATE=$rate DURATION=3600 POLL=100ms \
  STOP_BELOW_GBPS=$BASELINE_STOP STOP_HOLD=30 PACING=off
reset_pacing_caps
for k in 1 2 3; do
  for p in off on; do
    sleep 120
    ./run.sh "$t-p2-s4-cliff-$p-$k" MODE=up PROCS=1 STREAMS=16 RATE=$rate DURATION=240 PACING=$p
  done
done
