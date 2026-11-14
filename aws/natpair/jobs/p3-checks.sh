#!/bin/bash
# Phase 3, step 5: natpair#12's checks on the bench/simple build, with #13 on. Churn at 3,000 connections a second,
# 3 consecutive 60 s runs (p99 latency, bug 9). A 120 s churn run with a forced full copy of the connection table
# 40 s in (bar: no step-down, and 'connection table is full' lines to alert on). 3 takeovers at 2 Gbps. Then SYN and
# ACK probes from the receiver to the shared address and both NATs' own addresses, on ports outside 32768-60999
# (22, 8080, 61500) and inside it (40000, 50000).
. ./lib.sh
t=$NAT_INSTANCE_TYPE
rx_switch on
for k in 1 2 3; do
  ./run.sh "$t-p3-churn3000-$k" MODE=churn CHURN_RATE=3000 DURATION=60
done
owner=$(owner_nat)
standby=$(other_nat "$owner")
diag="$RESULTS/$t-p3-resync-diag.txt"
./run.sh "$t-p3-resync" MODE=churn CHURN_RATE=3000 DURATION=120 > /tmp/resync-run.log 2>&1 &
run=$!
sleep 60
{
  echo "== before $(date -u +%T)"; on "$owner" 30 "cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait"
  on "$standby" 60 "conntrackd -C /var/lib/natpair/conntrackd.conf -n; echo requested a full copy"
  sleep 20
  echo "== after $(date -u +%T)"; on "$owner" 30 "cat /proc/sys/net/netfilter/nf_conntrack_count"
} >> "$diag" 2>&1
wait $run
tail -3 /tmp/resync-run.log
for k in 1 2 3; do
  wait_standby_ready || exit 1
  ./run.sh "$t-p3-takeover-$k" MODE=up PROCS=1 STREAMS=16 RATE=62.5M DURATION=60 HANDOVER_AT=20 PING=1
done
wait_standby_ready
out="$RESULTS/$t-p3-ext-probe.txt"
command -v nmap > /dev/null || dnf install -y -q nmap > /dev/null 2>&1
owner=$(owner_nat)
shared=$(shared_private_ip)
own_a=$(aws ec2 describe-instances --instance-ids "$NAT_A" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
own_b=$(aws ec2 describe-instances --instance-ids "$NAT_B" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
{
  echo "owner $owner, shared $shared, nat a $own_a ($NAT_A), nat b $own_b ($NAT_B)"
  on "$owner" 60 "iptables -Z; iptables -t raw -Z; echo counters zeroed" | head -1
  for scan in sS sA; do
    for ip in "$shared" "$own_a" "$own_b"; do
      echo "== nmap -$scan $ip"
      nmap -Pn -n -$scan -p 22,8080,61500,40000,50000 --reason -T4 --max-retries 1 "$ip" | grep -E "^[0-9]+/tcp|Nmap scan"
    done
  done
  echo "== owner firewall counters after the probes (nonzero)"
  on "$owner" 60 'iptables -t raw -L -v -n -x | awk "\$1 > 0 || /^Chain/"; iptables -L -v -n -x | awk "\$1 > 0 || /^Chain/"'
} > "$out" 2>&1
cat "$out"
