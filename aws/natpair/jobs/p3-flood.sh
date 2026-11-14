#!/bin/bash
# Phase 3, step 4: natpair#13 raises the primary ENI's receive threads above forwarding, so a flood to the owner's
# own address could now take CPU from forwarding. While the owner forwards TCP uploads at TCP_CAP (4.5 Gbps on the
# medium, 10 on the large), the receiver floods the owner's primary private address over the peering with 64-byte
# UDP or TCP SYNs from random ports to random ports at 1M packets a second. #13 off then on, 3 rounds, plus one
# round without a flood for reference.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for rx in off on; do
  rx_switch "$rx"
  ./run.sh "$t-p3-flood-rx$rx-none-1" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60 PING=1
done
for k in 1 2 3; do
  for rx in off on; do
    rx_switch "$rx"
    for f in udp syn; do
      wait_standby_ready || exit 1
      ./run.sh "$t-p3-flood-rx$rx-$f-$k" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60 PING=1 FLOOD=$f FLOOD_PPS=1000000
    done
  done
done
rx_switch on
