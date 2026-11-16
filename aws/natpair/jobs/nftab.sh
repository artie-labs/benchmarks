#!/bin/bash
# Native nftables against iptables (RESULTS.md, "nftables vs iptables"), on one build that has both backends: natpair
# feat/nftables-prototype, whose `"firewall": "nftables"` setting installs native nftables tables at boot instead of
# iptables rules. Each NAT reads the setting at boot, so switching reboots each NAT.
# Queue sections as separate jobs (prepend CASES=... and the settings). CASES picks and orders them:
#   install   installs KEY (an archive under natpair/builds/ in the bucket, sha256 SHA) on both NATs, sets the backend
#             to BACKEND (iptables or nftables) and reboots each, the standby first, then the owner after a handover.
#             With KEY empty, only switches the backend
#   info      binary, backend, native tables and iptables chains on each NAT
#   load      RUNS (3) rounds of: TCP as fast as 32 flows go, then 64-byte UDP at 1.2M and 2.5M packets a second over
#             128 fixed flows (run.sh MODE=raw), 30 s each
#   fence     FENCE_RUNS (2) rounds: during light TCP and pings through the NAT, freeze the owner's daemon (SIGSTOP),
#             record when the owner's shared ENI stops sending and when the peer takes over, then let the daemon go on
# BACKEND also names the runs.
BACKEND=${BACKEND:-iptables}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
OUT=$RESULTS/nftab-$t
mkdir -p "$OUT"
say() { echo "$(date -u +%T) $*"; }

# wait_online <nat>: waits until SSM runs a command on the NAT again and natpair is active (the receiver's role can't
# describe SSM instances).
wait_online() {
  local i
  for ((i = 0; i < 40; i++)); do
    on "$1" 30 'systemctl is-active natpair' 2> /dev/null | grep -qx active && return 0
    sleep 10
  done
  return 1
}

# switch_one <nat>: installs the build if KEY is set, sets the backend and reboots.
switch_one() {
  local cmd="set -e"
  if [[ -n ${KEY:-} ]]; then
    cmd+="
aws s3 cp --only-show-errors s3://$BUCKET/natpair/builds/$KEY /tmp/np.tgz
echo '${SHA:?}  /tmp/np.tgz' | sha256sum -c > /dev/null
rm -rf /tmp/np; mkdir /tmp/np; tar -C /tmp/np -xzf /tmp/np.tgz
install -m 0755 /tmp/np/natpair /usr/local/bin/natpair"
  fi
  cmd+="
command -v nft > /dev/null || dnf install -y -q nftables > /dev/null
python3 -I -c 'import json, sys
p = \"/etc/natpair/config.json\"
c = json.load(open(p))
c.pop(\"firewall\", None)
if sys.argv[1] == \"nftables\":
    c[\"firewall\"] = \"nftables\"
json.dump(c, open(p, \"w\"), indent=2)' $BACKEND
natpair validate --config /etc/natpair/config.json > /dev/null
echo \"\$(sha256sum /usr/local/bin/natpair | cut -c1-8) firewall=\$(python3 -I -c 'import json; print(json.load(open(\"/etc/natpair/config.json\")).get(\"firewall\", \"iptables\"))')\"
systemd-run --on-active=2 systemctl reboot > /dev/null"
  say "$1: $(on "$1" 300 "$cmd" | head -1)"
  sleep 30
  wait_online "$1" || say "$1 not back online"
  on "$1" 60 'natpair resume' > /dev/null 2>&1
}

install() {
  local owner standby i
  wait_standby_ready
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  switch_one "$standby"
  sleep 20
  wait_standby_ready || exit 1
  on "$owner" 120 'natpair maintenance' > /dev/null
  for ((i = 0; i < 60; i++)); do
    [[ $(owner_nat) == "$standby" ]] && break
    sleep 2
  done
  say "owner now $(owner_nat)"
  switch_one "$owner"
  sleep 20
  wait_standby_ready
}

info() {
  local nat
  for nat in "$NAT_A" "$NAT_B"; do
    echo "== $nat $([[ $(owner_nat) == "$nat" ]] && echo owner || echo standby)"
    on "$nat" 60 'sha256sum /usr/local/bin/natpair | cut -c1-8; uname -r
      python3 -I -c "import json; print(\"firewall\", json.load(open(\"/etc/natpair/config.json\")).get(\"firewall\", \"iptables\"))"
      echo "nft tables: $(nft list tables 2> /dev/null | xargs)"; echo "iptables NATPAIR chains: $(iptables -S 2> /dev/null | grep -c NATPAIR)"
      nft list set ip natpair_fence grant 2> /dev/null | grep -o "expires [0-9a-z]*" | head -1'
  done | tee -a "$OUT/info.txt"
}

load() {
  local k
  for ((k = 1; k <= ${RUNS:-3}; k++)); do
    wait_standby_ready || exit 1
    ./run.sh "$t-$BACKEND-tcp-$k" MODE=up PROCS=1 STREAMS=16 DURATION=30 PING=1 | tail -1
    ./run.sh "$t-$BACKEND-raw1200k-$k" MODE=raw LEN=64 PROCS=8 STREAMS=8 RATE=600000 DURATION=30 PING=1 | tail -1
    ./run.sh "$t-$BACKEND-raw2500k-$k" MODE=raw LEN=64 PROCS=8 STREAMS=8 RATE=1250000 DURATION=30 PING=1 | tail -1
  done
}

fence() {
  local k owner standby log=/tmp/nftab-fence.log at
  for ((k = 1; k <= ${FENCE_RUNS:-2}; k++)); do
    wait_standby_ready || exit 1
    owner=$(owner_nat)
    standby=$(other_nat "$owner")
    ./run.sh "$t-$BACKEND-fence-$k" MODE=up PROCS=1 STREAMS=4 RATE=100M DURATION=45 PING=1 > "$log" 2>&1 &
    local run=$!
    for ((i = 0; i < 120; i++)); do
      at=$(grep -o 'load at [0-9TZ:-]*' "$log" | head -1 | cut -d' ' -f3)
      [[ -n $at ]] && break
      sleep 0.5
    done
    sleep $(($(date -u -d "$at" +%s) + 10 - $(date +%s)))
    # On the owner: freeze the daemon, then watch the shared ENI's transmit counter every 50 ms until it has sent
    # nothing (under 20 packets per 50 ms) for 2 s, or for 25 s at most.
    {
      echo "== fence $k: owner $owner, standby $standby"
      on "$owner" 60 'pid=$(systemctl show -p MainPID --value natpair); f=/sys/class/net/ens6/statistics/tx_packets
        t0=$(date +%s.%N); kill -STOP "$pid"; prev=$(cat $f); last=$t0
        while :; do
          sleep 0.05; now=$(date +%s.%N); cur=$(cat $f 2> /dev/null || echo gone)
          [[ $cur == gone ]] && { echo "shared ENI detached at +$(awk -v a=$t0 -v b=$now "BEGIN {printf \"%.2f\", b - a}") s"; break; }
          (( cur - prev >= 20 )) && last=$now; prev=$cur
          awk -v a=$last -v b=$now "BEGIN {exit !(b - a >= 2)}" && break
          awk -v a=$t0 -v b=$now "BEGIN {exit !(b - a >= 25)}" && break
        done
        echo "frozen at $(date -u -d @${t0%.*} +%T).${t0#*.} forwarding last seen +$(awk -v a=$t0 -v b=$last "BEGIN {printf \"%.2f\", b - a}") s"'
    } | tee -a "$OUT/fence.txt"
    wait $run
    {
      tail -1 "$log"
      echo "-- peer $standby"
      on "$standby" 60 "journalctl -u natpair -o short-iso-precise --since '-90s' | grep -E 'ownership acquired|forwarding open|ownership session ended' | cut -c1-230"
      echo "-- old owner $owner, after SIGCONT"
      on "$owner" 60 'kill -CONT $(systemctl show -p MainPID --value natpair); sleep 8
        journalctl -u natpair -o short-iso-precise --since "-90s" | grep -E "ownership session ended|fence|lease" | cut -c1-230 | tail -5'
    } | tee -a "$OUT/fence.txt"
  done
}

for c in ${CASES:-info}; do
  say "=== $c"
  "$c"
done
say "=== done"
