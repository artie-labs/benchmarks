#!/bin/bash
# Phase 2, scenarios 2 and 6 with pacing limited by AWS's bandwidth allowance, not the CPU cap, run right after the
# burst job while the allowance is at its baseline. Caps reset first. Fairness (one heavy worker, four light ones),
# pacing off then on; then handovers and pacing-off/on toggles with pacing on, and handovers with pacing off. 3 rounds.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
reset_pacing_caps
for k in 1 2 3; do
  for p in off on; do
    ./run.sh "$t-p2-capped-fair-$p-$k" MODE=fair LIGHT_RATE=100M DURATION=90 PACING=$p
  done
done
for k in 1 2 3; do
  for p in on off; do
    wait_standby_ready || exit 1
    ./run.sh "$t-p2-capped-handover-$p-$k" MODE=up PROCS=1 STREAMS=16 RATE=187M DURATION=120 HANDOVER_AT=60 PING=1 \
      RPOLL=10ms PACING=$p
  done
done
wait_standby_ready
for k in 1 2 3; do
  ./run.sh "$t-p2-capped-toggle-$k" MODE=up PROCS=1 STREAMS=16 RATE=187M DURATION=90 TOGGLE_AT=30 PING=1 RPOLL=10ms \
    PACING=on
done
