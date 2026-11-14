#!/bin/bash
# natpair#17: a 1M pps flood of the owner's own (primary) address with 64-byte UDP while it forwards TCP at TCP_CAP,
# guard on and off, 3 rounds. The guard is on the shared ENI only, so forwarding should keep its rate and the guard
# shouldn't engage.
BUILD=${BUILD:-xdp}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for g in ${SIDES:-on off}; do
    wait_standby_ready || exit 1
    ./run.sh "$t-$BUILD-flood-$g-udp-$k" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60 PING=1 FLOOD=udp FLOOD_PPS=1000000 GUARD=$g
  done
done
guard_switch on
