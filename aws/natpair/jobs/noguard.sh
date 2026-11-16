#!/bin/bash
# Is natpair#15 needed on a 2-vCPU NAT without the XDP guard (#17, closed)? Builds: natpair bench/no-guard-no15 (N:
# master with #9 and #11, plus #12 #16 #14) and bench/no-guard-15 (W: N plus #15). Run on c7gn.large NATs with
# c7gn.xlarge generators, which offer more small packets than a large forwards.
# Queue sections as separate jobs (prepend BUILD=... and CASES=...). CASES picks and orders them:
#   info       kernel, binary, services and the generators' iperf3 version and CPUs
#   udp        64-byte UDP at 4M, 2.5M and 1.2M packets a second, 3 runs of 60 s each (or UDP_RUNS="<pps>:<run> ..."),
#              over 128 flows, 64 from each of the 2 generators. GEN=raw (default) sends with flood (run.sh MODE=raw).
#              GEN=iperf uses 8 iperf3 processes of 8 flows on each generator, whose setup through the NAT fails
#              for some clients once the NAT is past what it forwards, so they offer less than asked
#   sustained  one 10-minute run of 64-byte UDP at 2.5M packets a second (GEN as for udp)
#   flood      1M packets a second of 64-byte UDP to the owner's own address from the receiver, over the peering,
#              while the generators send TCP at 10 Gbps. 2 runs of 60 s
#   tcp        one 60 s run of TCP as fast as 32 flows go
#   cap        #15's congestion cap (W only): sets congestion_handover_minutes to CAP_MINUTES (1) on both NATs,
#              restarts the daemons (the standby first; SKIP_SET=1 skips this), then drops LOSS (0.85) of the owner's
#              packets leaving the shared ENI with an iptables statistic rule, and records when the owner hands over.
#              No load
BUILD=${BUILD:-N}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
# Per-flow iperf3 rate for a total packet rate over 128 flows (2 generators x PROCS=8 x STREAMS=8) of 64-byte
# datagrams (512 bits each): pps * 512 / 128.
flow_rate() { echo "$(($1 * 4))"; }

info() {
  {
    for nat in "$NAT_A" "$NAT_B"; do
      echo "== $nat"
      on "$nat" 30 'uname -r; nproc; sha256sum /usr/local/bin/natpair | cut -c1-8; systemctl is-active natpair conntrackd irqbalance
        journalctl -u natpair -o cat | grep -m1 -o "\"release\":\"[^\"]*\""; grep -H . /sys/class/net/ens*/threaded
        cat /etc/natpair/config.json | python3 -c "import json, sys; c = json.load(sys.stdin); print(sorted(c))"'
    done
    for gen in $GENERATORS; do
      echo "== generator $gen"
      on "$gen" 30 'nproc; iperf3 --version | head -1'
    done
  } > "$RESULTS/$t-$BUILD-info.txt" 2>&1
  cat "$RESULTS/$t-$BUILD-info.txt"
}

udp() {
  local runs=${UDP_RUNS:-} k c rk
  if [[ -z $runs ]]; then
    for k in 1 2 3; do
      for c in 4000000 2500000 1200000; do runs+=" $c:$k"; done
    done
  fi
  for rk in $runs; do
    c=${rk%%:*} k=${rk##*:}
    wait_standby_ready || exit 1
    if [[ ${GEN:-raw} == raw ]]; then
      ./run.sh "$t-$BUILD-raw$((c / 1000))k-$k" MODE=raw LEN=64 PROCS=8 STREAMS=8 RATE=$((c / 2)) DURATION=60 PING=1
    else
      ./run.sh "$t-$BUILD-udp$((c / 1000))k-$k" MODE=udp LEN=64 PROCS=8 STREAMS=8 RATE="$(flow_rate "$c")" DURATION=60 PING=1
    fi
  done
}

sustained() {
  wait_standby_ready || exit 1
  if [[ ${GEN:-raw} == raw ]]; then
    ./run.sh "$t-$BUILD-rawsustained2500k" MODE=raw LEN=64 PROCS=8 STREAMS=8 RATE=1250000 DURATION=600 PING=1 POLL=100ms
  else
    ./run.sh "$t-$BUILD-sustained2500k" MODE=udp LEN=64 PROCS=8 STREAMS=8 RATE="$(flow_rate 2500000)" DURATION=600 PING=1 POLL=100ms
  fi
}

flood() {
  local k
  for k in 1 2; do
    wait_standby_ready || exit 1
    ./run.sh "$t-$BUILD-flood-own-$k" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60 PING=1 FLOOD=udp FLOOD_PPS=1000000
  done
}

tcp() {
  wait_standby_ready || exit 1
  ./run.sh "$t-$BUILD-tcp" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1
}

cap() {
  local minutes=${CAP_MINUTES:-1} loss=${LOSS:-0.85} owner standby nat i since out="$RESULTS/$t-$BUILD-cap.txt"
  local set_cap="python3 -c 'import json; p = \"/etc/natpair/config.json\"; c = json.load(open(p)); c[\"congestion_handover_minutes\"] = $minutes; json.dump(c, open(p, \"w\"))'"
  local show_cap="grep -o '\"congestion_handover_minutes\": *[0-9]*' /etc/natpair/config.json"
  # The NATs have no tc, so an iptables rule drops a random share of the packets leaving the shared ENI, forwarded and
  # the NAT's own (its probes) alike.
  local rule="-t mangle -I POSTROUTING 1 -o \$dev -m statistic --mode random --probability $loss -j DROP"
  {
    wait_standby_ready || exit 1
    owner=$(owner_nat)
    standby=$(other_nat "$owner")
    if [[ -z ${SKIP_SET:-} ]]; then
      echo "== set congestion_handover_minutes $minutes, standby $standby first"
      on "$standby" 60 "$set_cap && systemctl restart natpair && $show_cap"
      sleep 30
      wait_standby_ready || exit 1
      # Restarting the owner's daemon hands over to the standby, which already runs with the new setting.
      on "$owner" 60 "$set_cap && systemctl restart natpair && $show_cap"
      sleep 30
      wait_standby_ready || exit 1
      owner=$(owner_nat)
      standby=$(other_nat "$owner")
    fi
    on "$owner" 30 "$show_cap"
    since=$(date -u '+%F %T')
    echo "== $(date -u +%T) dropping $loss of the packets leaving the owner $owner's shared ENI (standby $standby)"
    on "$owner" 60 "dev=\$(ip -o -4 addr show | awk '\$4 ~ /^$(shared_private_ip)\\// {print \$2}'); echo shared dev \$dev
      iptables -w 5 $rule && iptables -w 5 -t mangle -L POSTROUTING -v -n | head -4"
    for ((i = 0; i < 72; i++)); do
      sleep 5
      [[ $(owner_nat) != "$owner" ]] && { echo "== $(date -u +%T) shared ENI moved to $(owner_nat)"; break; }
    done
    sleep 20
    for nat in "$owner" "$standby"; do
      echo "== journal of $nat since $since"
      on "$nat" 60 "journalctl -u natpair -o short-iso-precise --since '$since' | grep -E 'path is alive|congest|ownership|forwarding open|stepped|handing over|lease|not working yet' | grep -v '\"health round\".*\"congested\":false' | cut -c1-330 | tail -40
        iptables -w 5 -t mangle -S POSTROUTING | grep -- '--probability' | sed 's/^-A/-D/' | while read -r r; do iptables -w 5 -t mangle \$r && echo removed: \$r; done; true"
    done
    echo "owner after: $(owner_nat)"
  } > "$out" 2>&1
  cat "$out"
}

for c in ${CASES:-info udp sustained flood tcp}; do
  echo "=== $c $(date -u +%T)"
  "$c"
done
echo "=== done $(date -u +%T)"
