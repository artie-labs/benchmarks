#!/bin/bash
# Phase 3, step 3: what natpair#13 costs. TCP uploads at a fixed rate below saturation (8 Gbps on the large, 4 on
# the medium), 64-byte UDP at a fixed rate (400k and 300k packets a second), and TCP as fast as 32 flows go, 45 s
# each, #13 off then on, 3 rounds. NATs sampled once a second.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
case $t in
  c7gn.large) tcp=250M udp=3.2M ;;
  *) tcp=125M udp=2.4M ;;
esac
for k in 1 2 3; do
  for rx in off on; do
    rx_switch "$rx"
    ./run.sh "$t-p3-cost-rx$rx-tcpfixed-$k" MODE=up PROCS=1 STREAMS=16 RATE=$tcp DURATION=45 POLL=1s
    ./run.sh "$t-p3-cost-rx$rx-udpfixed-$k" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=$udp DURATION=45 POLL=1s
    ./run.sh "$t-p3-cost-rx$rx-tcpmax-$k" MODE=up PROCS=1 STREAMS=16 DURATION=45 POLL=1s
  done
done
