#!/bin/bash
# Phase 1, measurement 1: the drop phase sampled every 1 ms, run right after a burst job while the allowance is
# nearly spent. Shows how often the bandwidth counters change while AWS drops, below the 10 ms sampling of 2c.
. ./lib.sh
./run.sh "$NAT_INSTANCE_TYPE-drop-1ms" MODE=up PROCS=1 STREAMS=16 RATE=$BURST_CAP DURATION=900 POLL=1ms \
  STOP_BELOW_GBPS=$BASELINE_STOP STOP_HOLD=60
