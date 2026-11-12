#!/bin/bash
# Phase 2: what the NATs answer to TCP packets without SYN from outside the VPC. From the receiver, nmap's ACK probe
# (-sA) to the shared address and both NATs' own addresses, on ports outside 32768-60999 (22, 8080, 61500) and inside
# it (40000, 50000). Records nmap's verdict per port and the owner's firewall counters around the probes.
# Output: $RESULTS/<type>-p2-ext-probe.txt.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
out="$RESULTS/$t-p2-ext-probe.txt"
command -v nmap > /dev/null || dnf install -y -q nmap > /dev/null 2>&1
owner=$(owner_nat)
shared=$(shared_private_ip)
own_a=$(aws ec2 describe-instances --instance-ids "$NAT_A" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
own_b=$(aws ec2 describe-instances --instance-ids "$NAT_B" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
{
  echo "owner $owner, shared $shared, nat a $own_a, nat b $own_b"
  on "$owner" 60 "iptables -Z; iptables -t raw -Z; echo counters zeroed" | head -1
  for ip in "$shared" "$own_a" "$own_b"; do
    echo "== nmap -sA $ip"
    nmap -Pn -n -sA -p 22,8080,61500,40000,50000 --reason -T4 "$ip" | grep -E "^[0-9]+/tcp|Nmap scan"
  done
  echo "== owner firewall counters after the probes (nonzero)"
  on "$owner" 60 'iptables -t raw -L -v -n -x | awk "\$1 > 0 || /^Chain/"; iptables -L INPUT -v -n -x | awk "\$1 > 0 || /^Chain/"; iptables -L NATPAIR_INPUT -v -n -x 2>/dev/null | awk "\$1 > 0 || /^Chain/"'
} > "$out" 2>&1
cat "$out"
