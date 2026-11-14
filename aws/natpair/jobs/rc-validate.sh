#!/bin/bash
# Release candidate (natpair bench/release): a short final validation. The build has no pacing and no natpair#13,
# so no run sets PACING or RXTHREADS.
# 1. Kernel and binary on both NATs, and one short TCP and churn run.
# 2. 3 planned handovers at 2 Gbps (`natpair maintenance` on the owner 20 s in, `natpair resume` after): ping and
#    receiver gap, takeovers, and each new owner's interrupt layout (irq.txt).
# 3. TCP as fast as 32 flows go (60 s) and TCP with 88-byte segments from 64 flows (90 s), 3 rounds each.
# 4. 3,000 connections a second, 3 consecutive 60 s runs, then a 120 s run with a forced full copy 60 s in.
# 5. SYN and ACK probes from the receiver to the shared address and both own addresses, 3 rounds. Then 3 bursts of
#    200 ACKs to one worker port on the shared address from one source, followed by 10 s at 50 ACKs a second.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
info="$RESULTS/$t-rc-info.txt"
for nat in "$NAT_A" "$NAT_B"; do
  echo "== $nat"
  on "$nat" 30 'uname -r; sha256sum /usr/local/bin/natpair; systemctl is-active natpair conntrackd irqbalance; journalctl -u natpair -o cat | grep -m1 -o "\"release\":\"[^\"]*\""'
done > "$info" 2>&1
cat "$info"
./run.sh "$t-rc-smoke-tcp" MODE=up PROCS=1 STREAMS=16 DURATION=20 PING=1
./run.sh "$t-rc-smoke-churn" MODE=churn CHURN_RATE=3000 DURATION=20
for k in 1 2 3; do
  wait_standby_ready || exit 1
  ./run.sh "$t-rc-handover-$k" MODE=up PROCS=1 STREAMS=16 RATE=62.5M DURATION=60 HANDOVER_AT=20 PING=1
done
for k in 1 2 3; do
  wait_standby_ready || exit 1
  ./run.sh "$t-rc-tcp-$k" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1
  wait_standby_ready || exit 1
  ./run.sh "$t-rc-overload88-$k" MODE=up PROCS=2 STREAMS=16 MSS=88 DURATION=90 PING=1
done
wait_standby_ready || exit 1
for k in 1 2 3; do
  ./run.sh "$t-rc-churn3000-$k" MODE=churn CHURN_RATE=3000 DURATION=60
done
owner=$(owner_nat)
standby=$(other_nat "$owner")
diag="$RESULTS/$t-rc-resync-diag.txt"
./run.sh "$t-rc-resync" MODE=churn CHURN_RATE=3000 DURATION=120 > /tmp/resync-run.log 2>&1 &
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
wait_standby_ready
out="$RESULTS/$t-rc-ext-probe.txt"
command -v nmap > /dev/null || dnf install -y -q nmap > /dev/null 2>&1
command -v tcpdump > /dev/null || dnf install -y -q tcpdump > /dev/null 2>&1
owner=$(owner_nat)
shared=$(shared_private_ip)
own_a=$(aws ec2 describe-instances --instance-ids "$NAT_A" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
own_b=$(aws ec2 describe-instances --instance-ids "$NAT_B" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
ports=22,8080,40000,50000,61000,61500,62000,65000
{
  echo "owner $owner, shared $shared, nat a $own_a ($NAT_A), nat b $own_b ($NAT_B)"
  on "$owner" 60 "iptables -Z; iptables -t raw -Z; echo counters zeroed" | head -1
  for k in 1 2 3; do
    for scan in sS sA; do
      for ip in "$shared" "$own_a" "$own_b"; do
        echo "== round $k nmap -$scan $ip"
        nmap -Pn -n -$scan -p "$ports" --reason -T4 --max-retries 1 "$ip" | grep -E "^[0-9]+/tcp"
      done
    done
    sleep 10
  done
  echo "== owner firewall counters after the probes (nonzero)"
  on "$owner" 60 'iptables -t raw -L -v -n -x | awk "\$1 > 0 || /^Chain/"; iptables -L -v -n -x | awk "\$1 > 0 || /^Chain/"'
  for k in 1 2 3; do
    sleep 15
    echo "== ACK burst round $k: 200 at 2000/s to $shared:40000, then 10 s at 50/s"
    python3 -I /opt/natpair-bench/ackburst.py "$shared" 40000 200 2000 10 50
  done
  echo "== owner hashlimit after the bursts"
  on "$owner" 30 'cat /proc/net/ipt_hashlimit/natpair_reset 2>/dev/null | head -5'
} > "$out" 2>&1
cat "$out"
