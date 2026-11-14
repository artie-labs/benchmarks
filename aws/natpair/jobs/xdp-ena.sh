#!/bin/bash
# ENA XDP limits on the standby (box/xdp.sh): MTU and queue limits, the gap an attach or detach causes, and the cost
# of dropping 64-byte UDP in XDP against the kernel's firewall drop, with floods from the receiver at 1M and 3M packets
# a second. No natpair change, no load through the pair. KERNEL names the kernel in the label.
KERNEL=${KERNEL:-k}
. ./lib.sh
label=$(date -u +%Y%m%dT%H%M%SZ)-$NAT_INSTANCE_TYPE-$KERNEL-xdp
wait_standby_ready || exit 1
owner=$(owner_nat)
standby=$(other_nat "$owner")
ip_of() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text; }
owner_ip=$(ip_of "$owner")
standby_ip=$(ip_of "$standby")
t0=$(($(date +%s) + 30))
echo "xdp $label: standby $standby ($standby_ip), owner $owner ($owner_ip), T0 $(date -u -d "@$t0" +%FT%TZ)"
id=$(ssm_send "$standby" 600 "aws s3 cp --only-show-errors --region $AWS_REGION s3://$BUCKET/box/xdp.sh /tmp/natpair-bench-xdp.sh && env AWS_REGION=$AWS_REGION BUCKET=$BUCKET LABEL=$label T0=$t0 PEER=$owner_ip bash /tmp/natpair-bench-xdp.sh")
flood() { # start offset, pps, tag
  sleep "$((t0 + $1 - $(date +%s)))"
  ./bin/flood -target "$standby_ip" -mode udp -pps "$2" -duration 20s -out "/tmp/natpair-bench-flood-$label-$3.json"
  aws s3 cp --only-show-errors "/tmp/natpair-bench-flood-$label-$3.json" "s3://$BUCKET/runs/xdp/$label/flood-$3.json"
}
flood 75 1000000 nox-1m
flood 100 3000000 nox-3m
flood 130 1000000 xdp-1m
flood 155 3000000 xdp-3m
ssm_wait "$id" "$standby" || echo "xdp.sh did not succeed on $standby"
# Nothing may stay attached: print the interface and MTU as they are now.
on "$standby" 60 "ip -d link show dev ens5 | grep -E 'mtu|xdp'; ethtool -l ens5 | tail -5"
echo "files in s3://$BUCKET/runs/xdp/$label/"
