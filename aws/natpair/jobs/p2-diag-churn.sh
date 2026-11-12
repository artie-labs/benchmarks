#!/bin/bash
# Phase 2, scenario 5 follow-up: under connection churn the owner sent about 3 times as many packets out of the
# shared ENI as it received, and pps_allowance_exceeded moved. Runs churn at 3,000 connections a second with pacing
# off twice, and halfway through each captures what leaves the shared ENI, the firewall's counters and the kernel's
# TCP and conntrack counters on the owner. Output: $RESULTS/<run>-diag.txt.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2; do
  owner=$(owner_nat)
  on "$owner" 180 "command -v tcpdump > /dev/null || dnf install -y -q tcpdump > /dev/null 2>&1; echo ready"
  ./run.sh "$t-p2-diag-churn-$k" MODE=churn CHURN_RATE=3000 DURATION=120 PACING=off > /tmp/diag-run.log 2>&1 &
  run=$!
  sleep 85
  on "$owner" 180 '
    iptables -Z; iptables -t nat -Z; nstat -n
    timeout 5 tcpdump -i ens6 -nn -Q out -w /tmp/out.pcap -c 50000 2> /dev/null
    timeout 5 tcpdump -i ens6 -nn -Q in -w /tmp/in.pcap -c 50000 2> /dev/null
    sleep 1
    echo "== packets out of ens6 by TCP flags (5 s, at most 50000)"
    tcpdump -nn -r /tmp/out.pcap 2> /dev/null | grep -o "Flags \[[^]]*\]" | sort | uniq -c | sort -rn | head
    echo "== packets into ens6 by TCP flags"
    tcpdump -nn -r /tmp/in.pcap 2> /dev/null | grep -o "Flags \[[^]]*\]" | sort | uniq -c | sort -rn | head
    echo "== sample of RST packets out"
    tcpdump -nn -r /tmp/out.pcap 2> /dev/null | grep "Flags \[R" | head -5
    echo "== sources and destinations of packets out (top)"
    tcpdump -nn -r /tmp/out.pcap 2> /dev/null | awk "{print \$3, \$5}" | sed -E "s/\.[0-9]+ / /; s/\.[0-9]+:$//" | sort | uniq -c | sort -rn | head -5
    echo "== iptables filter (nonzero, about 7 s)"
    iptables -L -v -n -x | awk "\$1 > 0 || /^Chain/"
    echo "== iptables nat (nonzero)"
    iptables -t nat -L -v -n -x | awk "\$1 > 0 || /^Chain/"
    echo "== nstat since the reset"
    nstat | grep -iE "Rst|Reset|Abort|AttemptFail|InErr|OutSeg|InSeg|Retrans|Drop|Listen"
    echo "== conntrack"
    cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max
    sysctl net.netfilter.nf_conntrack_tcp_timeout_time_wait net.netfilter.nf_conntrack_tcp_timeout_close_wait net.netfilter.nf_conntrack_tcp_be_liberal net.netfilter.nf_conntrack_tcp_loose
    conntrack -L -o extended 2> /dev/null | awk "{print \$4}" | sort | uniq -c | sort -rn | head
  ' > "$RESULTS/$t-p2-diag-churn-$k-diag.txt" 2>&1
  wait $run
  cat /tmp/diag-run.log | tail -3
done
