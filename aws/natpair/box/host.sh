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
uname -r > kernel.txt
# Generators and the receiver use a 1500-byte MTU, as paths through an internet gateway do, so the NAT forwards
# internet-sized packets. DHCP sets 9001 at boot, so this sets it before every run and records it.
if [[ $role != nat ]]; then
  dev=$(ip -o route show default | awk '{print $5; exit}')
  ip link set dev "$dev" mtu 1500
  cat "/sys/class/net/$dev/mtu" > mtu.txt
fi
list_interfaces > interfaces-start.txt
# Fetched every run, so a rebuilt enapoll reaches every host.
aws s3 cp --only-show-errors "s3://$BUCKET/box/bin/enapoll" "$base/enapoll" && chmod +x "$base/enapoll"

if [[ $role == nat ]]; then
  # BPF run time per program (pacing's packet programs), counted only while kernel.bpf_stats_enabled is 1.
  command -v bpftool > /dev/null || dnf install -y -q bpftool > /dev/null 2>&1
  sysctl -qw kernel.bpf_stats_enabled=1
fi
if [[ $role == gen && $MODE == churn ]]; then
  aws s3 cp --only-show-errors "s3://$BUCKET/box/bin/churn" "$base/churn" && chmod +x "$base/churn"
fi

sleep_until "$START"
"$base/enapoll" -i auto -interval "$INTERVAL" -duration "${SAMPLE_SECONDS}s" -out enapoll.csv \
  -cpu cpu.csv -procs conntrackd,natpair,iperf3 2> enapoll.err &
sampler=$!
if [[ $role == nat ]]; then
  bpftool -j prog show > bpf-start.json 2> /dev/null
  # natpair#13: whether each interface runs threaded NAPI, and the nice value of the receive threads.
  { grep -H . /sys/class/net/ens*/threaded; ps -eo ni,comm | grep 'napi/'; } > threaded.txt 2>&1
  # Connection table size and the kernel's conntrack drops, once a second, for as long as enapoll samples, so a run
  # stopped early ends here too.
  (
    echo "t,count,drop,early_drop,insert_failed,error,search_restart"
    while kill -0 "$sampler" 2> /dev/null; do
      stats=$(conntrack -S 2> /dev/null | tr ' ' '\n' | awk -F= '
        $1 == "drop" { d += $2 } $1 == "early_drop" { e += $2 } $1 == "insert_failed" { i += $2 }
        $1 == "error" { r += $2 } $1 == "search_restart" { s += $2 }
        END { printf "%d,%d,%d,%d,%d", d, e, i, r, s }')
      echo "$(date +%s.%N),$(cat /proc/sys/net/netfilter/nf_conntrack_count),$stats"
      sleep 1
    done
  ) > conntrack.csv &
  # The caps pacing enforces, from its limits map, once a second: four costs in nanoseconds per unit (aggregate bytes
  # times 65536, aggregate packets, worker bytes times 65536, worker packets; 0 is no cap) and when they expire. The
  # map exists only while pacing is loaded.
  (
    while kill -0 "$sampler" 2> /dev/null; do
      echo "$(date +%s.%N) $(bpftool -j map dump name natpair_limits 2> /dev/null | tr -d '\n ')"
      sleep 1
    done
  ) > limits.txt &
fi

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

# Fairness: one heavy worker and four light ones, each from its own address. Generator 0 runs the heavy worker
# from its primary address (32 flows, unlimited) and a light one from its second. Generator 1 runs light ones from
# three addresses. A light worker is iperf3 with 2 flows at LIGHT_RATE each, and pings the receiver from its
# address 10 times a second.
run_fair() {
  local addrs pids=() k ip port
  read -r -a addrs <<< "$ADDRS"
  if [[ $GEN_INDEX == 0 ]]; then
    iperf3 -c "$RECEIVER_IP" -p 5201 -B "${addrs[0]}" -t "$DURATION" -P 32 -J > "iperf-heavy-${addrs[0]}.json" 2>&1 &
    pids+=($!)
    light_ips=("${addrs[1]}")
  else
    light_ips=("${addrs[0]}" "${addrs[1]}" "${addrs[2]}")
  fi
  k=0
  for ip in "${light_ips[@]}"; do
    port=$((5210 + GEN_INDEX * 4 + k))
    iperf3 -c "$RECEIVER_IP" -p "$port" -B "$ip" -t "$DURATION" -P 2 -b "$LIGHT_RATE" -J > "iperf-light-$ip.json" 2>&1 &
    pids+=($!)
    ping -D -I "$ip" -i 0.1 -w "$DURATION" "$RECEIVER_IP" > "ping-light-$ip.txt" 2>&1 &
    pids+=($!)
    k=$((k + 1))
  done
  wait "${pids[@]}"
}

# Churn: CHURN_RATE new connections a second in total, half from each generator, each sending CHURN_SIZE bytes.
run_churn() {
  ulimit -n 1048576
  "$base/churn" -target "$RECEIVER_IP" -ports 6000-6063 -rate "$((CHURN_RATE / GENERATORS_COUNT))" \
    -duration "${DURATION}s" -size "${CHURN_SIZE:-4096}" -out churn.json 2> churn.err
}

if [[ $role == gen && $MODE == fair ]]; then
  sleep_until "$LOAD_AT"
  run_fair
elif [[ $role == gen && $MODE == churn ]]; then
  sleep_until "$LOAD_AT"
  run_churn
elif [[ $role == gen && $MODE != none ]]; then
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
  # Halfway through a short run, 30 s into a long one, which may be stopped early.
  half=$((DURATION / 2))
  sleep_until "$((LOAD_AT + (half < 30 ? half : 30)))"
  ss -Htna '( sport >= :5201 and sport <= :5232 )' > peers.txt
  ss -Huna '( sport >= :5201 and sport <= :5232 )' >> peers.txt
fi

wait "$sampler"
gzip -f enapoll.csv
if [[ $role == nat ]]; then
  bpftool -j prog show > bpf-end.json 2> /dev/null
  # Which CPU each network queue's interrupt goes to. natpair spreads them, including after a takeover.
  for irq in $(grep -E 'ens[0-9]+-Tx-Rx' /proc/interrupts | cut -d: -f1); do
    echo "$(grep "^ *$irq:" /proc/interrupts | awk '{print $NF}') $(cat /proc/irq/$irq/effective_affinity_list)"
  done > irq.txt
  systemctl is-active irqbalance > irqbalance.txt 2>&1
  dmesg 2> /dev/null | grep -c 'table full' > conntrack-table-full.txt
fi
list_interfaces > interfaces-end.txt
if systemctl cat natpair > /dev/null 2>&1; then
  journalctl -u natpair -u conntrackd --since "@$START" -o short-iso-precise --no-pager > journal.txt
fi
wait
aws s3 cp --only-show-errors --recursive . "s3://$BUCKET/runs/$RUN/$instance/"
echo "uploaded $role $instance"
