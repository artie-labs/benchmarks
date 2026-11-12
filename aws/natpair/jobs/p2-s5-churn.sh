#!/bin/bash
# Phase 2, scenario 5: a new TCP connection for every 4 KB request, at 3,000 and 15,000 connections a second, toward
# production's packet rate. Connection table size and drops, conntrackd CPU and every allowance counter, pacing off
# then on, 3 rounds.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for rate in 3000 15000; do
    for p in off on; do
      ./run.sh "$t-p2-s5-churn$rate-$p-$k" MODE=churn CHURN_RATE=$rate DURATION=60 PACING=$p
    done
  done
done
