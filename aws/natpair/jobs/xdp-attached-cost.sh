#!/bin/bash
# What any XDP program on the shared ENI costs ENA's receive path: full-rate TCP from 32 flows with xdp/pass.c (XDP_PASS
# only) attached natively to the owner's shared ENI, against none, 3 rounds alternating by default. natpair's guard is off on both
# NATs throughout, so only the pass program is attached. The ring stays at its default. ROUNDS sets the rounds and
# SIDES the sides (pass none).
BUILD=${BUILD:-xdp}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
guard_switch off
for k in $(seq 1 "${ROUNDS:-3}"); do
  for side in ${SIDES:-pass none}; do
    wait_standby_ready || exit 1
    owner=$(owner_nat)
    if [[ $side == pass ]]; then
      on "$owner" 60 "aws s3 cp --only-show-errors s3://$BUCKET/box/bin/xdp_pass.o /tmp/xdp_pass.o && ip link set dev ens6 xdpdrv obj /tmp/xdp_pass.o sec xdp && ip -d link show ens6 | grep -o 'prog/xdp id [0-9]*'"
    fi
    ./run.sh "$t-$BUILD-attached-$side-tcp-$k" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1 GUARD=keep
    [[ $side == pass ]] && on "$owner" 60 "ip link set dev ens6 xdpdrv off; ip -d link show ens6 | grep -c 'prog/xdp'"
  done
done
guard_switch on
