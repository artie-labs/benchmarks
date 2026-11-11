#!/bin/bash
# Phase 1, measurement 4: TCP uploads at TCP_CAP (above the baseline bandwidth, below the CPU limit) until the NAT
# falls back to its baseline, then 60 s more. Records how long the burst lasts and the counters at the drop.
. ./lib.sh
./run.sh "$NAT_INSTANCE_TYPE-burst" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=3600 POLL=100ms \
  STOP_BELOW_GBPS=$BASELINE_STOP STOP_HOLD=60
