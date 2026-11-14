#!/bin/bash
# natpair#17 (XDP overload guard on the shared ENI) at saturation, guard on and off on the same pair: 64-byte UDP at
# 800k and 1.2M packets a second over 64 flows, TCP as fast as 32 flows go and TCP with 88-byte segments from 64
# flows, 60 s each, 3 rounds. Each round alternates which side goes first. Counts takeovers, lease, DNS and probe
# failures, the guard's engaged and cleared lines, and the shared ENI's rx_dropped share (NIC plus XDP drops).
# BUILD names the build in run names. SIDES="off" or "on" runs one side only, such as the off side while a new build
# of the guard is prepared, and CASES picks the loads.
BUILD=${BUILD:-xdp}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  sides="on off"
  ((k % 2 == 0)) && sides="off on"
  [[ -n ${SIDES:-} ]] && sides=$SIDES
  for c in ${CASES:-udp800k udp1200k tcp overload88}; do
    case $c in
      tcp) args=(MODE=up PROCS=1 STREAMS=16) ;;
      overload88) args=(MODE=up PROCS=2 STREAMS=16 MSS=88) ;;
      udp800k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=6.4M) ;;
      udp1200k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M) ;;
    esac
    for g in $sides; do
      wait_standby_ready || exit 1
      ./run.sh "$t-$BUILD-$g-$c-$k" "${args[@]}" DURATION=60 PING=1 GUARD=$g
    done
  done
done
guard_switch on
