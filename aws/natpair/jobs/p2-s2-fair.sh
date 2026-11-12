#!/bin/bash
# Phase 2, scenario 2: one heavy uploader (32 flows, unlimited) and four light workers at 2 x LIGHT_RATE each, from
# five distinct worker addresses. Light workers' throughput, TCP round trip and ping, pacing off then on, 3 rounds.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for p in off on; do
    ./run.sh "$t-p2-s2-fair-$p-$k" MODE=fair LIGHT_RATE=100M DURATION=60 PACING=$p
  done
done
