#!/bin/bash
# natpair#16 (threaded NAPI on every ENI) at saturation: TCP as fast as 32 flows go, TCP with 88-byte segments from
# 64 flows, and 64-byte UDP at 800k and 1.2M packets a second over 64 flows, 60 s each, 3 rounds. Counts takeovers,
# lease, DNS and probe failures, #15's path-alive lines and the daemon's CPU. BUILD names the build in run names.
BUILD=${BUILD:-napi}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for c in tcp overload88 udp800k udp1200k; do
    wait_standby_ready || exit 1
    case $c in
      tcp) args=(MODE=up PROCS=1 STREAMS=16) ;;
      overload88) args=(MODE=up PROCS=2 STREAMS=16 MSS=88) ;;
      udp800k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=6.4M) ;;
      udp1200k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M) ;;
    esac
    ./run.sh "$t-$BUILD-$c-$k" "${args[@]}" DURATION=60 PING=1
  done
done
