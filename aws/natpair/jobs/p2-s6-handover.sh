#!/bin/bash
# Phase 2, scenario 6, with pacing on and TCP uploads as fast as 32 flows go: `natpair maintenance` on the owner 60 s
# in (then resume), and separately `natpair pacing-off` on the owner 30 s in and `pacing-on` 20 s later. 100 pings a
# second and receiver samples every 10 ms measure the gaps. 3 rounds each.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  wait_standby_ready || exit 1
  ./run.sh "$t-p2-s6-handover-$k" MODE=up PROCS=1 STREAMS=16 DURATION=120 HANDOVER_AT=60 PING=1 RPOLL=10ms PACING=on
done
wait_standby_ready
for k in 1 2 3; do
  ./run.sh "$t-p2-s6-toggle-$k" MODE=up PROCS=1 STREAMS=16 DURATION=90 TOGGLE_AT=30 PING=1 RPOLL=10ms PACING=on
done
