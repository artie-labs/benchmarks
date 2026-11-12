#!/bin/bash
# Phase 2, scenario 5 on a build that sends conntrackd's copies through each NAT's own interface: churn at 3,000
# connections a second, pacing off then on, 3 rounds. Then one more run with pacing on that forces a full copy of
# the connection table 40 s in (`conntrackd -n` on the standby asks the owner for everything), and checks on the
# owner where the copies go, whether they fragment and whether the shared ENI still sends more than it receives.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  for p in off on; do
    ./run.sh "$t-p2-churn3000-$p-$k" MODE=churn CHURN_RATE=3000 DURATION=60 PACING=$p
  done
done
owner=$(owner_nat)
standby=$(other_nat "$owner")
on "$owner" 180 "command -v tcpdump > /dev/null || dnf install -y -q tcpdump > /dev/null 2>&1; echo ready" > /dev/null
./run.sh "$t-p2-resync" MODE=churn CHURN_RATE=3000 DURATION=120 PACING=on > /tmp/resync-run.log 2>&1 &
run=$!
sleep 60
check() {
  on "$owner" 120 "label=$1;"'
    echo "== $label $(date -u +%T)"
    nstat -az IpFragCreates IpFragOKs IpOutRequests > /dev/null; nstat -n
    rm -f /tmp/e5.pcap /tmp/e6.pcap
    timeout 3 tcpdump -i ens5 -nn -Q out -w /tmp/e5.pcap udp port 3780 or "ip[6:2] & 0x1fff != 0" 2> /dev/null &
    timeout 3 tcpdump -i ens6 -nn -Q out -w /tmp/e6.pcap 2> /dev/null &
    wait
    echo "-- conntrackd copies out of ens5 (own ENI) in 3 s: $(tcpdump -nn -r /tmp/e5.pcap udp port 3780 2> /dev/null | wc -l) datagrams, $(tcpdump -nn -r /tmp/e5.pcap "ip[6:2] & 0x1fff != 0" 2> /dev/null | wc -l) fragments"
    tcpdump -nn -r /tmp/e5.pcap 2> /dev/null | head -2
    echo "-- out of ens6 (shared) in 3 s: $(tcpdump -nn -r /tmp/e6.pcap 2> /dev/null | wc -l) packets, $(tcpdump -nn -r /tmp/e6.pcap udp port 3780 2> /dev/null | wc -l) to port 3780, $(tcpdump -nn -r /tmp/e6.pcap "ip[6:2] & 0x1fff != 0" 2> /dev/null | wc -l) fragments"
    echo "-- fragments the kernel made in those 3 s"; nstat IpFragCreates IpFragOKs
    ip route get $(grep -o "IPv4_Destination_Address [0-9.]*" /var/lib/natpair/conntrackd.conf | cut -d" " -f2)
    ss -uanp | grep conntrackd
  '
}
check before-resync >> "$RESULTS/$t-p2-resync-diag.txt" 2>&1
on "$standby" 60 "conntrackd -C /var/lib/natpair/conntrackd.conf -n; echo requested a full copy" >> "$RESULTS/$t-p2-resync-diag.txt" 2>&1
sleep 2
check during-resync >> "$RESULTS/$t-p2-resync-diag.txt" 2>&1
wait $run
tail -3 /tmp/resync-run.log
