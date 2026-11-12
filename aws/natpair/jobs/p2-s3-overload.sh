#!/bin/bash
# Phase 2, scenario 3: TCP uploads with 88-byte segments from 64 flows, unlimited, past what the NAT's CPU forwards.
# Phase 1 saw the pair flap here. Takeovers, lease and probe failures and the busiest CPU, pacing off then on.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for p in off on; do
    ./run.sh "$t-p2-s3-overload-$p-$k" MODE=up PROCS=2 STREAMS=16 MSS=88 DURATION=90 PACING=$p
  done
done
