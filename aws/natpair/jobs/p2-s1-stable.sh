#!/bin/bash
# Phase 2, scenario 1: the highest TCP upload rate at which the pair stays stable without pacing, as the bar for
# paced throughput. 32 flows at fixed totals (medium: 7, 8 and 9 Gbps; large: 11, 13 and 15 Gbps), pacing off
# then on at each rate, 3 rounds. A rate is stable when no run at it has a takeover. Runs are 60 s, well inside the
# burst allowance.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
case $t in
  c7gn.medium) rates="219M 250M 281M" ;;
  c7gn.large) rates="344M 406M 469M" ;;
esac
for k in 1 2 3; do
  for r in $rates; do
    for p in off on; do
      ./run.sh "$t-p2-s1-stable-$r-$p-$k" MODE=up PROCS=1 STREAMS=16 RATE=$r DURATION=60 PACING=$p
    done
  done
done
