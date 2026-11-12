#!/bin/bash
# Phase 1, measurements 1 and 4: the drop phase sampled every 10 ms. TCP uploads at BURST_CAP until the burst
# allowance runs out, then 120 s of AWS dropping at the baseline, then a stop. Shows the counters at the transition,
# how often they change while AWS drops for bandwidth, and their last change after the load stops.
. ./lib.sh
./run.sh "$NAT_INSTANCE_TYPE-drop-10ms" MODE=up PROCS=1 STREAMS=16 RATE=$BURST_CAP DURATION=3600 POLL=10ms \
  STOP_BELOW_GBPS=$BASELINE_STOP STOP_HOLD=120
