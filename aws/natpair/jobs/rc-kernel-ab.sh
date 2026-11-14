#!/bin/bash
# Same build, other kernel line: TCP as fast as 32 flows go (60 s) and TCP with 88-byte segments from 64 flows (90 s),
# 3 rounds each, as in rc-validate. KERNEL names the kernel in the run names. Compares the owner's lease, DNS and
# probe failures and the daemon's CPU at 100% CPU between kernel lines.
KERNEL=${KERNEL:-k}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  wait_standby_ready || exit 1
  ./run.sh "$t-$KERNEL-tcp-$k" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1
  wait_standby_ready || exit 1
  ./run.sh "$t-$KERNEL-overload88-$k" MODE=up PROCS=2 STREAMS=16 MSS=88 DURATION=90 PING=1
done
