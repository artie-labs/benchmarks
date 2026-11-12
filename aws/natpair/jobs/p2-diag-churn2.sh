#!/bin/bash
# Phase 2, scenario 5 follow-up: the shared ENI sends 3 times what it receives only in a second churn run in a row,
# when natpair asks for a full copy of the connection table. Two runs back to back at 3,000 connections a second,
# pacing off. During the second, at 30, 60 and 90 s into the load, captures 3 s of what leaves the shared ENI on
# whichever NAT holds it, by protocol and destination, with conntrackd's sync statistics.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
./run.sh "$t-p2-diag2-churn-1" MODE=churn CHURN_RATE=3000 DURATION=90 PACING=off
./run.sh "$t-p2-diag2-churn-2" MODE=churn CHURN_RATE=3000 DURATION=120 PACING=off > /tmp/diag2-run.log 2>&1 &
run=$!
sleep 25
for at in 30 60 90; do
  sleep 30
  owner=$(owner_nat)
  on "$owner" 120 '
    command -v tcpdump > /dev/null || dnf install -y -q tcpdump > /dev/null 2>&1
    echo "== $(hostname) $(date -u +%T) owner"
    conntrackd -C /run/natpair/conntrackd.conf -s 2>/dev/null | head -30 || conntrackd -s 2>/dev/null | head -30
    rm -f /tmp/o.pcap; timeout 3 tcpdump -i ens6 -nn -Q out -w /tmp/o.pcap 2> /dev/null
    echo "== out of ens6 in 3 s, by protocol and destination"
    tcpdump -nn -r /tmp/o.pcap 2> /dev/null | awk "{split(\$5, d, \".\"); proto = (\$0 ~ /UDP|udp/) ? \"udp\" : \"tcp\"; print proto, d[1]\".\"d[2]\".\"d[3]\".\"d[4]}" | sort | uniq -c | sort -rn | head -6
    echo "== udp sample"
    tcpdump -nn -r /tmp/o.pcap udp 2> /dev/null | head -3
    echo "== nat conntrack events and sync"
    ss -uanp | grep -E "3780|conntrackd" | head -5
    ls /run/natpair /var/lib/natpair 2> /dev/null | head
  ' >> "$RESULTS/$t-p2-diag2-churn-2-diag.txt" 2>&1
done
wait $run
tail -3 /tmp/diag2-run.log
