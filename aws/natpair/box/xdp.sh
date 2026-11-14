#!/bin/bash
# ENA XDP checks on the standby NAT's primary interface: what attaching a native XDP program needs (MTU, queues) and
# changes (channels, a link reset, a gap in traffic), and what dropping a UDP flood in XDP costs against the
# kernel's own drop. Started through SSM by jobs/xdp-ena.sh, which floods this NAT from the receiver at the times
# below, counted from T0. Usage: env BUCKET=... AWS_REGION=... LABEL=<name> T0=<epoch> PEER=<owner private IP> bash xdp.sh
#
# It refuses to run on the NAT that holds the shared ENI. A guard timer and an exit trap detach the program and
# restore the MTU and channels, so a lost SSM session can't leave the interface changed.
set -u
dev=ens5
out=/tmp/natpair-bench-xdp/$LABEL
rm -rf "$out"
mkdir -p "$out"
cd "$out" || exit 1
exec > log.txt 2>&1
now() { date +%s.%N; }
mark() { echo "$(now) $*"; }
at() { sleep "$(awk -v t="$((T0 + $1))" -v n="$(now)" 'BEGIN { d = t - n; if (d < 0) d = 0; print d }')"; }
upload() { aws s3 cp --only-show-errors --recursive . "s3://$BUCKET/runs/xdp/$LABEL/"; }

if [[ -e /sys/class/net/ens6 ]]; then
  mark "this NAT holds the shared ENI: refusing"
  upload
  exit 1
fi
mtu0=$(cat "/sys/class/net/$dev/mtu")
combined0=$(ethtool -l "$dev" | awk '/^Current hardware settings/ { c = 1 } c && /^Combined:/ { print $2; exit }')
max_combined=$(ethtool -l "$dev" | awk '/^Pre-set maximums/ { c = 1 } c && /^Combined:/ { print $2; exit }')
restore() {
  ip link set dev "$dev" xdpdrv off 2> /dev/null
  ip link set dev "$dev" xdp off 2> /dev/null
  [[ $(cat "/sys/class/net/$dev/mtu") == "$mtu0" ]] || ip link set dev "$dev" mtu "$mtu0"
  [[ $(ethtool -l "$dev" | awk '/^Current hardware settings/ { c = 1 } c && /^Combined:/ { print $2; exit }') == "$combined0" ]] ||
    ethtool -L "$dev" combined "$combined0"
}
cat > /tmp/natpair-bench-xdp-guard.sh << EOF
ip link set dev $dev xdpdrv off
ip link set dev $dev mtu $mtu0
ethtool -L $dev combined $combined0
EOF
systemctl stop natpair-bench-xdp-guard.timer 2> /dev/null
systemd-run --unit natpair-bench-xdp-guard --on-active=420 /bin/bash /tmp/natpair-bench-xdp-guard.sh
trap 'mark cleanup; restore; ip -d link show dev $dev > link-final.txt; ethtool -l $dev > channels-final.txt; upload' EXIT
trap 'exit 1' TERM INT

aws s3 cp --only-show-errors "s3://$BUCKET/box/bin/xdp_pass.o" .
aws s3 cp --only-show-errors "s3://$BUCKET/box/bin/xdp_drop.o" .
{
  uname -r
  ethtool -i "$dev"
  ethtool -l "$dev"
  ethtool -g "$dev"
  ip -d link show dev "$dev"
  echo "mtu $mtu0 combined $combined0 of $max_combined"
} > facts.txt 2>&1
# The owner answers pings from its peer. A gap in replies is a gap in this interface's traffic.
ping -D -i 0.01 -W 1 -w 420 "$PEER" > ping.txt 2>&1 &
pinger=$!
ip -ts monitor link dev "$dev" > link-events.txt 2>&1 &
monitor=$!
dmesg_mark=$(dmesg | wc -l)

attach() { # program, label
  local rc
  ethtool -S "$dev" > "stats-before-$2.txt"
  mark "attach $1 ($2) mtu $(cat /sys/class/net/$dev/mtu)"
  ip link set dev "$dev" xdpdrv obj "$1" sec xdp > "attach-$2.txt" 2>&1
  rc=$?
  mark "attach $2 done rc $rc: $(tr '\n' ' ' < "attach-$2.txt")"
  ethtool -l "$dev" > "channels-$2.txt"
  ip -d link show dev "$dev" >> "channels-$2.txt"
  return $rc
}
detach() {
  mark "detach ($1)"
  ip link set dev "$dev" xdpdrv off
  mark "detach $1 done rc $?"
  ethtool -l "$dev" > "channels-detach-$1.txt"
}

at 5
attach xdp_pass.o mtu-default && detach mtu-default
at 12
ip link set dev "$dev" mtu 3499 && mark "mtu 3499"
attach xdp_pass.o mtu-3499 && detach mtu-3499
at 20
ip link set dev "$dev" mtu 3498 && mark "mtu 3498"
at 30
if ! attach xdp_pass.o pass-1; then
  # ENA wants as many free queues as XDP uses for its own transmit rings.
  half=$((max_combined / 2))
  ((half < 1)) && half=1
  mark "channels $combined0 -> $half"
  ethtool -L "$dev" combined "$half"
  mark "channels done rc $?"
  at 35
  attach xdp_pass.o pass-1b
fi
at 45
detach pass-1
at 55
attach xdp_pass.o pass-2
at 65
detach pass-2

# Flood phases: the receiver sends 64-byte UDP to this NAT's address at 75-95 s (1M pps) and 100-120 s (3M pps)
# without XDP, so the kernel drops it in the firewall, and at 130-150 s and 155-175 s with xdp_drop.o attached.
sample() { # label
  local d=sample-$1
  mkdir -p "$d"
  now > "$d/time"
  cat /proc/stat > "$d/stat"
  cat /proc/softirqs > "$d/softirqs"
  ethtool -S "$dev" > "$d/ethtool"
  cat "/sys/class/net/$dev/statistics/rx_packets" > "$d/rx_packets"
}
at 80; sample nox-1m-a
at 90; sample nox-1m-b
at 105; sample nox-3m-a
at 115; sample nox-3m-b
at 125
attach xdp_drop.o drop
at 135; sample xdp-1m-a
at 145; sample xdp-1m-b
at 160; sample xdp-3m-a
at 170; sample xdp-3m-b
at 180
detach drop
restore
mark "restored mtu $(cat /sys/class/net/$dev/mtu) combined $(ethtool -l "$dev" | awk '/^Current hardware settings/ { c = 1 } c && /^Combined:/ { print $2; exit }')"
at 190
kill "$pinger" "$monitor" 2> /dev/null
dmesg -T | tail -n +"$((dmesg_mark + 1))" > dmesg.txt
systemctl stop natpair-bench-xdp-guard.timer 2> /dev/null
