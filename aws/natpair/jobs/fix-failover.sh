#!/bin/bash
# natpair#15 fail-over check: a dead path must still make the owner step down. TCP uploads at 2 Gbps with ping; about 25 s
# in, the owner drops everything it sends through the shared ENI to addresses outside the VPC (forwarded traffic and
# its own probes and handshakes alike). systemd-run removes each rule 150 s later, so the old owner can serve again. One
# timer per rule: systemd reads a ';' in a transient unit's command line as a command separator.
# Bar: the owner steps down, the standby takes over, and the path check logs no `the path is alive`.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
out="$RESULTS/$t-fix-failover.txt"
wait_standby_ready || exit 1
owner=$(owner_nat)
shared=$(shared_private_ip)
vpc=10.40.0.0/16
./run.sh "$t-fix-failover-1" MODE=up PROCS=1 STREAMS=16 RATE=62.5M DURATION=120 PING=1 > /tmp/failover-run.log 2>&1 &
run=$!
sleep 30
{
  echo "owner $owner, shared $shared"
  on "$owner" 30 "dev=\$(ip -o -4 addr show | awk '\$4 ~ /^$shared\\// {print \$2}'); echo shared dev \$dev; \
    iptables -I FORWARD 1 -o \$dev ! -d $vpc -j DROP -m comment --comment bench-blackhole; \
    iptables -I OUTPUT 1 -o \$dev ! -d $vpc -j DROP -m comment --comment bench-blackhole; \
    systemd-run --on-active=150 --unit=bench-unblackhole-fwd iptables -D FORWARD -o \$dev ! -d $vpc -j DROP -m comment --comment bench-blackhole; \
    systemd-run --on-active=150 --unit=bench-unblackhole-out iptables -D OUTPUT -o \$dev ! -d $vpc -j DROP -m comment --comment bench-blackhole; \
    echo blackhole on at \$(date -u +%T)"
  for ((i = 0; i < 60; i++)); do
    [[ $(owner_nat) != "$owner" ]] && { echo "owner moved to $(owner_nat) at $(date -u +%T)"; break; }
    sleep 3
  done
} > "$out" 2>&1
wait $run
tail -2 /tmp/failover-run.log >> "$out"
sleep 60
{
  echo "== old owner after the rule's removal"
  on "$owner" 30 "iptables -S | grep -c bench-blackhole; journalctl -u natpair -o cat --since '-6min' | grep -E 'path is alive|failed to check whether|ownership session ended|probe_error\":\"' | cut -c1-400 | tail -8"
} >> "$out" 2>&1
cat "$out"
