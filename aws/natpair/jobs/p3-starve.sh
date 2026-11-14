#!/bin/bash
# Phase 3, step 1 (RX=off) and step 2 (RX=on): does a CPU-saturated owner lose its lease, DNS or probes, and does
# natpair#13's control-plane priority keep them? 64-byte UDP at 800k and 1.2M packets a second over 64 flows, TCP
# with 88-byte segments from 64 flows, and full-size TCP as fast as 32 flows go, 60 s each, 3 rounds. The pair must
# be ready before each run, so a takeover in one run doesn't carry into the next.
RX=${RX:-off}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
rx_switch "$RX"
for k in 1 2 3; do
  for c in udp800k udp1200k tcp88 tcp; do
    wait_standby_ready || exit 1
    case $c in
      udp800k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=6.4M) ;;
      udp1200k) args=(MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M) ;;
      tcp88) args=(MODE=up PROCS=2 STREAMS=16 MSS=88) ;;
      tcp) args=(MODE=up PROCS=1 STREAMS=16) ;;
    esac
    ./run.sh "$t-p3-starve-rx$RX-$c-$k" "${args[@]}" DURATION=60 PING=1
  done
done
