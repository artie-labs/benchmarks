#!/bin/bash
# natpair#17: one planned handover with the guard on, during 64-byte UDP at 1.2M packets a second. The new owner must
# attach the guard to the shared ENI before it opens forwarding (its journal and the run's nic-end.txt show it), and
# the old owner must detach.
BUILD=${BUILD:-xdp}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
guard_switch on
wait_standby_ready || exit 1
old=$(owner_nat)
./run.sh "$t-$BUILD-takeover-1" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M DURATION=60 PING=1 HANDOVER_AT=20
new=$(owner_nat)
echo "owner before $old, after $new"
for nat in "$new" "$old"; do
  echo "== $nat"
  on "$nat" 60 "ip -d link show | grep -B1 -A0 'prog/xdp' | head -4; journalctl -u natpair -o cat --since '-4min' | grep -E 'overload guard|forwarding open|ownership acquired|ownership session ended|turned on threaded' | cut -c1-300 | tail -12"
done
