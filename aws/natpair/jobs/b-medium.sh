#!/bin/bash
# natpair#15 on another kernel line: rc-udp's small-UDP overload (64 B at 800k and 1.2M packets a second, 64 flows)
# and rc-kernel-ab's TCP as fast as 32 flows go, 60 s each, 3 rounds. BUILD names the build and kernel in run names.
BUILD=${BUILD:-fix}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for c in udp800k udp1200k tcp; do
    wait_standby_ready || exit 1
    case $c in
      udp800k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=6.4M) ;;
      udp1200k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M) ;;
      tcp) args=(MODE=up PROCS=1 STREAMS=16) ;;
    esac
    ./run.sh "$t-$BUILD-$c-$k" "${args[@]}" DURATION=60 PING=1
  done
done
