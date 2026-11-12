#!/bin/bash
# Phase 1, measurement 2: each direction at the capped rates, 3 interleaved rounds. TCP down at TCP_CAP, and UDP
# 64-byte payloads up and down at UDP_CAP. Down replies leave through the owner's own ENI, so down runs split the
# packets over both ENIs. A short idle refills minutes of burst, so these show what the NAT forwards within its
# burst. 2c-drop-10ms shows the rate after the burst.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  ./run.sh "$t-limit-down-$k" MODE=down PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=90
  ./run.sh "$t-limit-udp-up-$k" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=$UDP_CAP DURATION=60
  ./run.sh "$t-limit-udp-down-$k" MODE=udpdown LEN=64 PROCS=1 STREAMS=8 RATE=$UDP_CAP DURATION=60
done
