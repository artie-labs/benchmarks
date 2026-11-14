#!/bin/bash
# Release candidate: small-UDP overload. 64-byte UDP at 800k and 1.2M packets a second over 64 flows through the NAT,
# 60 s, 3 rounds, counting takeovers, lease, DNS and probe failures and ping loss. Phase 3 saw these flap on kernel
# 6.1. BUILD names the build in the run names. The pair must be ready before each run, so a takeover in one run
# doesn't carry into the next.
BUILD=${BUILD:-rc}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for c in udp800k udp1200k; do
    wait_standby_ready || exit 1
    case $c in
      udp800k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=6.4M) ;;
      udp1200k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M) ;;
    esac
    ./run.sh "$t-$BUILD-$c-$k" "${args[@]}" DURATION=60 PING=1
  done
done
