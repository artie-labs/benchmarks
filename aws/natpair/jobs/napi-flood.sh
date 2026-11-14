#!/bin/bash
# natpair#16: a flood of the owner's own address while it forwards. TCP uploads at TCP_CAP (4.5 Gbps on the medium,
# 10 on the large) while the receiver floods the owner's primary private address over the peering with 64-byte UDP
# or TCP SYNs at 1M packets a second, 3 rounds, plus one run without a flood. As phase 3's p3-flood, without #13's
# switch: #16 has no off switch, and phase 3's off side is the comparison.
BUILD=${BUILD:-napi}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
wait_standby_ready || exit 1
./run.sh "$t-$BUILD-flood-none-1" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60 PING=1
for k in 1 2 3; do
  for f in udp syn; do
    wait_standby_ready || exit 1
    ./run.sh "$t-$BUILD-flood-$f-$k" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60 PING=1 FLOOD=$f FLOOD_PPS=1000000
  done
done
