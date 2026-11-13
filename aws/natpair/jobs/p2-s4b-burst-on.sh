#!/bin/bash
# Phase 2, scenario 4 on a build whose caps start uncapped: does pacing use the burst allowance, and what does it do
# at the cliff? TCP uploads offered at BURST_CAP (8 Gbps on the medium) with pacing on until the receiver falls back
# near the baseline for 60 s, sampled every 100 ms. Then 2 rounds of 2 idle minutes and 240 s at the same rate,
# pacing off then on, so each run crosses the cliff of a partly refilled allowance.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
# Pacing must be attached to the owner's interfaces, with its programs on the shared ENI's egress.
on "$(owner_nat)" 60 "natpair pacing-on > /dev/null; sleep 2; for i in ens5 ens6; do echo \"\$i: \$(tc filter show dev \$i egress | grep -o 'name natpair_[a-z]*')\"; done"
./run.sh "$t-p2-s4b-spend-on" MODE=up PROCS=1 STREAMS=16 RATE=$BURST_CAP DURATION=3600 POLL=100ms \
  STOP_BELOW_GBPS=$BASELINE_STOP STOP_HOLD=60 PACING=on
for k in 1 2; do
  for p in off on; do
    sleep 120
    ./run.sh "$t-p2-s4b-cliff-$p-$k" MODE=up PROCS=1 STREAMS=16 RATE=$BURST_CAP DURATION=240 POLL=100ms PACING=$p
  done
done
