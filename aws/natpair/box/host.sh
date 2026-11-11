#!/bin/bash
# One host's part of a run, started by run.sh through SSM (or directly on the receiver). Usage: host.sh nat|gen|recv.
# Samples the ENA counters and CPU with enapoll from START for SAMPLE_SECONDS, runs the iperf3 load on generators,
# then uploads everything to s3://$BUCKET/runs/$RUN/<instance id>/. Settings come from the environment run.sh sets.
set -uo pipefail
role=$1
base=/tmp/natpair-bench
dir=$base/$RUN
mkdir -p "$dir"
cd "$dir" || exit 1
export AWS_REGION AWS_DEFAULT_REGION=$AWS_REGION

imds() {
  local token
  token=$(curl -s -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)
  curl -s -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

# Sleeps until the given Unix time, which may have a fraction.
sleep_until() {
  sleep "$(awk -v t="$1" -v n="$(date +%s.%N)" 'BEGIN { d = t - n; if (d < 0) d = 0; printf "%.3f", d }')"
}

# Lists each ENA interface with its ENI ID and IPv4 addresses, to tell the shared ENI from the primary one.
list_interfaces() {
  local link name mac
  for link in /sys/class/net/*/device/driver; do
    [[ $(basename "$(readlink "$link")") == ena ]] || continue
    name=$(basename "$(dirname "$(dirname "$link")")")
    mac=$(cat "/sys/class/net/$name/address")
    echo "$name $(imds "network/interfaces/macs/$mac/interface-id") $(ip -4 -o addr show dev "$name" | awk '{print $4}' | paste -sd, -)"
  done
}

instance=$(imds instance-id)
echo "$role" > role.txt
# Generators and the receiver use a 1500-byte MTU, as paths through an internet gateway do, so the NAT forwards
# internet-sized packets. DHCP sets 9001 at boot, so this sets it before every run and records it.
if [[ $role != nat ]]; then
  dev=$(ip -o route show default | awk '{print $5; exit}')
  ip link set dev "$dev" mtu 1500
  cat "/sys/class/net/$dev/mtu" > mtu.txt
fi
list_interfaces > interfaces-start.txt
if [[ ! -x $base/enapoll ]]; then
  aws s3 cp --only-show-errors "s3://$BUCKET/box/bin/enapoll" "$base/enapoll" && chmod +x "$base/enapoll"
fi

sleep_until "$START"
"$base/enapoll" -i auto -interval "$INTERVAL" -duration "${SAMPLE_SECONDS}s" -out enapoll.csv \
  -cpu cpu.csv -procs conntrackd,natpair,iperf3 2> enapoll.err &
sampler=$!

# One iperf3 client process per receiver port, PROCS per generator, each with STREAMS flows.
run_clients() {
  local seconds=$1 tag=$2 port args=() pids=()
  args=(-t "$seconds" -P "$STREAMS" -J)
  [[ $MODE == down || $MODE == udpdown ]] && args+=(-R)
  [[ -n $MSS ]] && args+=(--set-mss "$MSS")
  if [[ $MODE == udp || $MODE == udpdown ]]; then
    args+=(-u -b "${RATE:-0}")
    [[ -n $LEN ]] && args+=(-l "$LEN")
  elif [[ -n $RATE ]]; then
    args+=(-b "$RATE")
  fi
  for ((j = 0; j < PROCS; j++)); do
    port=$((5201 + GEN_INDEX * PROCS + j))
    iperf3 -c "$RECEIVER_IP" -p "$port" "${args[@]}" > "iperf-$tag-$port.json" 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}"
}

if [[ $role == gen && $MODE != none ]]; then
  if [[ $PING == 1 ]]; then
    # 100 probes a second for the whole load. A gap in replies is a pause in forwarding.
    timeout "$((SAMPLE_SECONDS - PRE))" ping -D -O -i 0.01 -W 1 "$RECEIVER_IP" > ping.txt 2>&1 &
  fi
  sleep_until "$LOAD_AT"
  if [[ $PATTERN == onoff ]]; then
    cycles=$((DURATION / (ON + OFF)))
    for ((c = 0; c < cycles; c++)); do
      sleep_until "$((LOAD_AT + c * (ON + OFF)))"
      run_clients "$ON" "c$c"
    done
  else
    run_clients "$DURATION" steady
  fi
fi

if [[ $role == recv ]]; then
  # Which sources the receiver sees. Every worker flow should come from the shared ENI's private address.
  sleep_until "$((LOAD_AT + DURATION / 2))"
  ss -Htna '( sport >= :5201 and sport <= :5232 )' > peers.txt
  ss -Huna '( sport >= :5201 and sport <= :5232 )' >> peers.txt
fi

wait "$sampler"
gzip -f enapoll.csv
list_interfaces > interfaces-end.txt
if systemctl cat natpair > /dev/null 2>&1; then
  journalctl -u natpair -u conntrackd --since "@$START" -o short-iso-precise --no-pager > journal.txt
fi
wait
aws s3 cp --only-show-errors --recursive . "s3://$BUCKET/runs/$RUN/$instance/"
echo "uploaded $role $instance"
