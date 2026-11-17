#!/bin/bash
# Release regression battery (RESULTS.md, "Release regression battery"): natpair v0.1.1 against the release candidate
# on the same pair, with the fail-over cases from fck-nat-ha's AWS test plan that apply to a bench without EKS.
# scripts/submit-regress.sh queues it with jobs/ctsize.sh's helpers (hold fills, samplers, copy waits) in front, and
# with BUILD= and CASES= on the first line. Sections, run in the order given:
#   info       kernel, binary, release, table limit, conntrackd buffers, threaded NAPI and memory on both NATs
#   handover   A6: HOLD idle connections, then 2 planned handovers (`natpair maintenance` 20 s into light TCP with
#              pings): pause, flows that broke, the idle connections the new owner kept
#   kill       A2: 2 rounds of SIGKILL to the owner's daemon 20 s into light TCP with pings. systemd restarts it
#   blackhole  B1: the owner drops everything it sends through the shared ENI outside the VPC for 150 s: it must
#              step down and the standby take over
#   resync     Copy completeness under churn: BIG idle connections, churn at CHURN new connections a second, the
#              standby's conntrackd restarted 20 s in (a forced full copy), `natpair maintenance` 100 s in
#   full       A full connection table: hold fills it, churn into it for 60 s (no step-down), then the owner's daemon
#              is killed and kept down (the standby must take over once), memory throughout
#   flood      UDP through the shared address past what the NAT forwards: 2 x 60 s of 64-byte packets over 128
#              fixed flows at FLOOD_PPS, and 30 s of TCP as fast as 32 flows go
#   clear      resets every hold connection
# Light TCP is 32 flows at LIGHT a flow: 400 Mbit/s on a c7g.medium (its baseline is 500), 2 Gbit/s otherwise.
BUILD=${BUILD:?}
OUT=$RESULTS/regress-$t-$BUILD
mkdir -p "$OUT"
TAG=$BUILD
case $t in
  c7g.medium) LIGHT=${LIGHT:-12.5M} HOLD=${HOLD:-20000} BIG=${BIG:-50000} CHURN=${CHURN:-1000} FLOOD_PPS=${FLOOD_PPS:-1200000} ;;
  *) LIGHT=${LIGHT:-62.5M} HOLD=${HOLD:-20000} BIG=${BIG:-100000} CHURN=${CHURN:-3000} FLOOD_PPS=${FLOOD_PPS:-2500000} ;;
esac
MIN_AVAIL_MB=${MIN_AVAIL_MB:-250}

private_ip() {
  aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
}

# wait_load <run log>: waits until run.sh has printed its load time, then prints it in epoch seconds.
wait_load() {
  local at i
  for ((i = 0; i < 120; i++)); do
    at=$(grep -o 'load at [0-9TZ:-]*' "$1" | head -1 | cut -d' ' -f3)
    [[ -n $at ]] && { date -u -d "$at" +%s; return 0; }
    sleep 0.5
  done
  return 1
}

sleep_to() {
  local d=$(($1 - $(date +%s)))
  ((d > 0)) && sleep "$d"
  return 0
}

# brief <run name>: one line from the run's summary: ping, iperf3 and the journals' counts.
brief() {
  python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1])); m = s["meta"]; h = s["hosts"]
c = {}
for x in h.values():
    for k, v in ((x.get("journal") or {}).get("counts") or {}).items():
        c[k] = c.get(k, 0) + v
ping = next((x["ping"] for x in h.values() if x.get("ping")), {}) or {}
it = s.get("iperf_total") or {}
churn = [x["churn"] for x in h.values() if x.get("churn")]
failed = {}
for x in churn:
    for k, v in (x.get("failed") or {}).items():
        failed[k] = failed.get(k, 0) + v
o = h.get(m["owner"], {})
allow = {}
for nat in (m["owner"], m["standby"]):
    for label, r in ((h.get(nat, {}).get("steady")) or {}).items():
        for k, v in (r or {}).items():
            if "allowance" in k and k.endswith("_per_s") and v:
                allow[k.replace("_allowance_exceeded_per_s", "")] = allow.get(k.replace("_allowance_exceeded_per_s", ""), 0) + v
sh = (o.get("steady") or {}).get("ens6 (shared)") or {}
print(m["run"], "| ping loss %s%% gap %ss" % (ping.get("loss_pct"), ping.get("longest_gap_s")),
      "| iperf %s Gbps errors %d %s" % (it.get("received_gbps"), len(it.get("errors") or []), (it.get("errors") or [])[:1]),
      "| acquired", c.get("ownership_acquired"), "ended", c.get("stepped_down"), "lease", c.get("lease_store_unreachable"),
      "dns", c.get("dns_or_probe_timeout"), "probe", c.get("probe_errors"), "cong", c.get("congested_rounds"),
      "| shared tx %s pps rx %s pps" % (sh.get("tx_pps"), sh.get("rx_pps")),
      "| allowance/s", allow or 0,
      ("| churn completed/s %.0f failed %s p99 %s" % (sum(x.get("completed_per_second", 0) for x in churn), failed,
       [x.get("latency_ms_p99") for x in churn])) if churn else "")' "$(result_of "$1")" | tee -a "$OUT/runs.txt"
}

info() {
  local nat
  for nat in "$NAT_A" "$NAT_B"; do
    echo "== $nat $( [[ $nat == $(owner_nat) ]] && echo owner || echo standby)"
    on "$nat" 60 'uname -r; sha256sum /usr/local/bin/natpair | cut -c1-16; systemctl is-active natpair conntrackd irqbalance | xargs
      journalctl -u natpair -o cat | grep "\"health round\"" | tail -1 | grep -o "\"release\":\"[^\"]*\""
      echo max_connections $(python3 -I -c "import json; print(json.load(open(\"/etc/natpair/config.json\")).get(\"max_connections\"))")
      echo nf_conntrack_max $(cat /proc/sys/net/netfilter/nf_conntrack_max) buckets $(cat /proc/sys/net/netfilter/nf_conntrack_buckets) time_wait $(cat /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait)
      grep -E "SocketBuffer|ResendQueue|HashLimit|HashSize|NetlinkBuffer" /var/lib/natpair/conntrackd.conf | xargs
      echo threaded $(for d in /sys/class/net/ens*; do echo "$(basename $d)=$(cat $d/threaded 2>/dev/null)"; done)
      awk "/MemTotal|MemAvailable/ {printf \"%s %d MB \", \$1, \$2 / 1024}" /proc/meminfo; echo; nproc'
  done | tee "$OUT/info.txt"
}

handover() {
  fill_to "$HOLD"
  local k old new before after
  for k in 1 2; do
    ready_wait 300 || return 1
    old=$(owner_nat)
    new=$(other_nat "$old")
    before=$(table_count "$old")
    ./run.sh "$t-$BUILD-handover-$k" MODE=up PROCS=1 STREAMS=16 RATE="$LIGHT" DURATION=60 HANDOVER_AT=20 PING=1 > /tmp/regress-run.log 2>&1
    after=$(table_count "$new")
    say "handover $k: $old -> $(owner_nat), old owner table $before, new owner table $after" | tee -a "$OUT/runs.txt"
    brief "$t-$BUILD-handover-$k"
  done
  events handover "$(($(date +%s) - 300))" > /dev/null
}

kill_owner() {
  local k owner standby log=/tmp/regress-run.log load
  for k in $(seq "${KILLS:-2}"); do
    ready_wait 300 || return 1
    owner=$(owner_nat)
    standby=$(other_nat "$owner")
    ./run.sh "$t-$BUILD-kill-$k" MODE=up PROCS=1 STREAMS=16 RATE="$LIGHT" DURATION=90 PING=1 > "$log" 2>&1 &
    local run=$!
    load=$(wait_load "$log") || return 1
    sleep_to $((load + 20))
    {
      echo "== kill $k: owner $owner, standby $standby"
      on "$owner" 30 'pid=$(systemctl show -p MainPID --value natpair); kill -9 $pid; echo killed $pid at $(date -u +%T.%N | cut -c1-12)'
      for ((i = 0; i < 40; i++)); do
        [[ $(owner_nat) != "$owner" ]] && { echo "shared ENI on $(owner_nat) at $(date -u +%T)"; break; }
        sleep 1
      done
    } >> "$OUT/kill.txt" 2>&1
    wait $run
    {
      on "$standby" 60 "journalctl -u natpair -o short-iso-precise --since '-150s' | grep -E 'ownership acquired|forwarding open|ownership session ended|handoff step|shared ENI change|threaded|shared Elastic IP|identity prepared|lease' | cut -c1-260"
      on "$owner" 60 "journalctl -u natpair -o short-iso-precise --since '-150s' | grep -E 'ownership acquired|forwarding open|ownership session ended|Started|kernel deadline|fence' | cut -c1-200 | tail -8"
    } >> "$OUT/kill.txt" 2>&1
    brief "$t-$BUILD-kill-$k"
  done
  tail -40 "$OUT/kill.txt"
}

blackhole() {
  ready_wait 300 || return 1
  local owner shared vpc=10.40.0.0/16 log=/tmp/regress-run.log
  owner=$(owner_nat)
  shared=$(shared_private_ip)
  ./run.sh "$t-$BUILD-blackhole" MODE=up PROCS=1 STREAMS=16 RATE="$LIGHT" DURATION=120 PING=1 > "$log" 2>&1 &
  local run=$!
  sleep 30
  {
    echo "== blackhole: owner $owner, shared $shared"
    on "$owner" 30 "dev=\$(ip -o -4 addr show | awk '\$4 ~ /^$shared\\// {print \$2}'); echo shared dev \$dev; \
      iptables -I FORWARD 1 -o \$dev ! -d $vpc -j DROP -m comment --comment bench-blackhole; \
      iptables -I OUTPUT 1 -o \$dev ! -d $vpc -j DROP -m comment --comment bench-blackhole; \
      systemd-run --on-active=150 --unit=bench-unblackhole-fwd-\$RANDOM iptables -D FORWARD -o \$dev ! -d $vpc -j DROP -m comment --comment bench-blackhole; \
      systemd-run --on-active=150 --unit=bench-unblackhole-out-\$RANDOM iptables -D OUTPUT -o \$dev ! -d $vpc -j DROP -m comment --comment bench-blackhole; \
      echo blackhole on at \$(date -u +%T)"
    for ((i = 0; i < 60; i++)); do
      [[ $(owner_nat) != "$owner" ]] && { echo "owner moved to $(owner_nat) at $(date -u +%T)"; break; }
      sleep 2
    done
  } >> "$OUT/blackhole.txt" 2>&1
  wait $run
  brief "$t-$BUILD-blackhole"
  sleep 100
  {
    echo "== old owner after the rule's removal"
    on "$owner" 30 "iptables -S | grep -c bench-blackhole; journalctl -u natpair -o short-iso-precise --since '-6min' | grep -E 'path is alive|ownership session ended|ownership acquired|stepped down' | cut -c1-300 | tail -6"
  } >> "$OUT/blackhole.txt" 2>&1
  cat "$OUT/blackhole.txt"
}

resync_churn() {
  fill_to "$BIG"
  ready_wait 300 || return 1
  local owner standby log=/tmp/regress-run.log load target got t0 i
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  samplers sample "$t-$BUILD-resync" 400
  ./run.sh "$t-$BUILD-resync" MODE=churn CHURN_RATE="$CHURN" DURATION=180 PRE=3 POST=3 > "$log" 2>&1 &
  local run=$!
  load=$(wait_load "$log") || return 1
  sleep_to $((load + 20))
  {
    target=$(table_count "$owner")
    t0=$(date +%s)
    on "$standby" 60 "systemctl restart conntrackd" > /dev/null
    say "resync: restarted conntrackd on standby $standby, owner table $target"
    for i in 10 20 30 45 60; do
      sleep_to $((t0 + i))
      say "resync +${i}s: owner table $(table_count "$owner"), standby external $(external_count "$standby")"
    done
    say "resync: $(ready_after "$standby" "$t0") s to ready (empty = not ready)"
    sleep_to $((load + 100))
    target=$(table_count "$owner")
    t0=$(date +%s)
    on "$owner" 200 "natpair maintenance" > /dev/null &
    local m=$!
    for ((i = 0; i < 120; i++)); do
      [[ $(owner_nat) == "$standby" ]] && break
      sleep 1
    done
    say "handover: shared ENI on $(owner_nat) after about $(($(date +%s) - t0)) s, old owner table $target"
    wait $m
    sleep 3
    say "handover: new owner table $(table_count "$standby"), new standby external $(external_count "$owner")"
  } 2>&1 | tee -a "$OUT/resync.txt"
  wait $run
  samplers stop
  on "$owner" 60 "natpair resume" > /dev/null
  brief "$t-$BUILD-resync"
  events resync "$((load - 10))" | tee -a "$OUT/resync.txt" | head -4
}

full() {
  local owner standby max log=/tmp/regress-run.log load
  ready_wait 300 || return 1
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  max=$(on "$owner" 30 "cat /proc/sys/net/netfilter/nf_conntrack_max" | first_line)
  snap "$BUILD-full-before"
  samplers sample "$t-$BUILD-full" 1500
  FILL_RATE=20000 fill_to "$max" | tee -a "$OUT/full.txt"
  snap "$BUILD-full-filled"
  ./run.sh "$t-$BUILD-full-churn" MODE=churn CHURN_RATE=2000 DURATION=90 PRE=3 POST=3 > "$log" 2>&1 &
  local run=$!
  load=$(wait_load "$log") || return 1
  sleep_to $((load + 60))
  {
    owner=$(owner_nat)
    standby=$(other_nat "$owner")
    # This block runs in a subshell (the pipe to tee), so the NAT to restart afterwards goes through a file.
    echo "$owner" > /tmp/regress-killed
    say "full: owner $owner table $(table_count "$owner") of $max, killing and stopping its daemon"
    on "$owner" 30 "systemctl kill -s SIGKILL natpair; sleep 0.3; systemctl stop natpair; echo killed at \$(date -u +%T.%N | cut -c1-12)"
    for ((i = 0; i < 60; i++)); do
      [[ $(owner_nat) == "$standby" ]] && { say "shared ENI on $standby"; break; }
      sleep 1
    done
  } 2>&1 | tee -a "$OUT/full.txt"
  wait $run
  brief "$t-$BUILD-full-churn"
  sleep 20
  snap "$BUILD-full-after-takeover"
  samplers stop
  events full "$((load - 400))" | tee -a "$OUT/full.txt" | head -4
  owner=$(cat /tmp/regress-killed)
  on "$owner" 60 "systemctl start natpair; sleep 2; echo $owner natpair \$(systemctl is-active natpair)" | tee -a "$OUT/full.txt"
  ready_wait 300 || say "the restarted NAT $owner never became a ready standby" | tee -a "$OUT/full.txt"
  clear_all | tee -a "$OUT/full.txt"
}

flood() {
  local k
  for k in 1 2; do
    ready_wait 300 || true
    ./run.sh "$t-$BUILD-flood-$k" MODE=raw LEN=64 PROCS=8 STREAMS=8 RATE=$((FLOOD_PPS / 2)) DURATION=60 PING=1 > /tmp/regress-run.log 2>&1
    brief "$t-$BUILD-flood-$k"
  done
  ready_wait 300 || true
  ./run.sh "$t-$BUILD-tcp" MODE=up PROCS=1 STREAMS=16 DURATION=30 PING=1 > /tmp/regress-run.log 2>&1
  brief "$t-$BUILD-tcp"
}

# sustained: 10 minutes of 64-byte UDP at 1.2M packets a second over 128 fixed flows (the #15 check: the congestion
# window hands over after 10 minutes of congestion).
sustained() {
  ready_wait 300 || true
  ./run.sh "$t-$BUILD-sustained1200k" MODE=raw LEN=64 PROCS=8 STREAMS=8 RATE=600000 DURATION=600 PING=1 POLL=100ms > /tmp/regress-run.log 2>&1
  brief "$t-$BUILD-sustained1200k"
  local nat
  for nat in "$NAT_A" "$NAT_B"; do
    on "$nat" 60 "echo == $nat; journalctl -u natpair -o short-iso-precise --since '-12min' | grep -E 'ownership acquired|forwarding open|ownership session ended|handing over because|shared Elastic IP' | cut -c1-260 | tail -12" >> "$OUT/sustained.txt" 2>&1
  done
  cat "$OUT/sustained.txt"
}

# floodover: takeovers during 64-byte UDP at 1.2M packets a second: a planned handover 20 s in, then SIGKILL to the
# owner's daemon 20 s in. The new owner must open forwarding through the flood.
floodover() {
  local owner log=/tmp/regress-run.log load
  ready_wait 300 || true
  owner=$(owner_nat)
  ./run.sh "$t-$BUILD-floodhandover" MODE=raw LEN=64 PROCS=8 STREAMS=8 RATE=600000 DURATION=60 HANDOVER_AT=20 PING=1 > "$log" 2>&1
  say "flood handover: owner $owner -> $(owner_nat)" | tee -a "$OUT/floodover.txt"
  brief "$t-$BUILD-floodhandover"
  sleep 30
  ready_wait 300 || true
  owner=$(owner_nat)
  ./run.sh "$t-$BUILD-floodkill" MODE=raw LEN=64 PROCS=8 STREAMS=8 RATE=600000 DURATION=60 PING=1 > "$log" 2>&1 &
  local run=$!
  load=$(wait_load "$log") || return 1
  sleep_to $((load + 20))
  {
    on "$owner" 30 'pid=$(systemctl show -p MainPID --value natpair); kill -9 $pid; echo killed $pid at $(date -u +%T.%N | cut -c1-12)'
    for ((i = 0; i < 60; i++)); do
      [[ $(owner_nat) != "$owner" ]] && { say "shared ENI on $(owner_nat)"; break; }
      sleep 1
    done
  } 2>&1 | tee -a "$OUT/floodover.txt"
  wait $run
  brief "$t-$BUILD-floodkill"
  for nat in "$NAT_A" "$NAT_B"; do
    on "$nat" 60 "journalctl -u natpair -o short-iso-precise --since '-6min' | grep -E 'ownership acquired|forwarding open|ownership session ended|shared Elastic IP|in the last 10 minutes|path is alive' | cut -c1-260 | tail -12" >> "$OUT/floodover.txt" 2>&1
  done
  tail -30 "$OUT/floodover.txt"
}

# Idle connections with a socket at both ends (box/idle.py): the receiver echoes on port 8000, generator 0 holds them.
idle_server() {
  pgrep -f 'idle.py serve' > /dev/null || { nohup python3 -I ./idle.py serve 8000 >> /root/idle-serve.log 2>&1 & }
  sleep 1
}
idle_open() {
  on "${gens[0]}" 120 "aws s3 cp --only-show-errors --region $AWS_REGION s3://$BUCKET/box/idle.py /tmp/idle.py; rm -rf /tmp/idle-$1
    nohup python3 -I /tmp/idle.py hold $receiver_ip 8000 $2 /tmp/idle-$1 > /tmp/idle-$1.log 2>&1 &
    for i in \$(seq 100); do [[ -e /tmp/idle-$1/opened ]] && break; sleep 0.2; done; cat /tmp/idle-$1/opened /tmp/idle-$1.log" | head -2
}
idle_check() {
  on "${gens[0]}" 60 "touch /tmp/idle-$1/check-$2; for i in \$(seq 80); do [[ -e /tmp/idle-$1/result-$2.json ]] && break; sleep 0.25; done; cat /tmp/idle-$1/result-$2.json" | head -1
}
idle_stop() { on "${gens[0]}" 30 "touch /tmp/idle-$1/stop" > /dev/null; }
ct_port() { on "$1" 60 "conntrack -L -p tcp --dport 8000 2> /dev/null | grep -c ESTABLISHED" | first_line; }

# idleho: does a handover right after the standby's copy is ready keep idle connections? Each round opens IDLE idle
# connections, reboots the standby (as an upgrade does), waits for its first ready round, waits DELAYS' next value,
# runs `natpair maintenance` on the owner, then checks every connection 15 s after the shared ENI moved.
idleho() {
  local k=0 delay owner standby t0 r i n=${IDLE:-500} out="$OUT/idleho.txt"
  idle_server
  for delay in ${DELAYS:-0 0 0 25 120 120}; do
    k=$((k + 1))
    ready_wait 300 || return 1
    owner=$(owner_nat)
    standby=$(other_nat "$owner")
    {
      say "round $k delay $delay: owner $owner, standby $standby, opened $(idle_open r$k "$n")"
      say "before: $(idle_check r$k 0), owner entries $(ct_port "$owner"), standby copy $(external_count "$standby")"
      t0=$(date +%s)
      on "$standby" 30 "nohup sh -c 'sleep 1; systemctl reboot' > /dev/null 2>&1 &" > /dev/null
      sleep 15
      r=
      for ((i = 0; i < 150; i++)); do
        r=$(ready_after "$standby" "$t0")
        [[ -n $r ]] && break
        sleep 2
      done
      say "standby ready ${r:-never} s after the reboot command, copy $(external_count "$standby"), owner table $(table_count "$owner")"
      sleep "$delay"
      say "handover: owner table $(table_count "$owner"), standby copy $(external_count "$standby"), idle entries owner $(ct_port "$owner")"
      on "$owner" 200 "natpair maintenance" > /dev/null &
      local m=$!
      for ((i = 0; i < 120; i++)); do
        [[ $(owner_nat) == "$standby" ]] && break
        sleep 1
      done
      say "shared ENI on $(owner_nat)"
      wait $m
      on "$owner" 60 "natpair resume" > /dev/null
      sleep 15
      say "after: $(idle_check r$k 1), new owner entries $(ct_port "$standby"), table $(table_count "$standby")"
      idle_stop r$k
    } 2>&1 | tee -a "$out"
  done
}

# ctdump: what a full `conntrack -L` dump costs on the owner near a full table: fills to 95% of the limit, then 3
# rounds of 40 s TCP as fast as 32 flows go, with `conntrack -L > /dev/null` started on the owner 10 s in during
# rounds 2 and 3 (time, CPU, RSS), against round 1 without.
ctdump() {
  local owner max k log=/tmp/regress-run.log load out="$OUT/ctdump.txt"
  ready_wait 300 || true
  owner=$(owner_nat)
  max=$(on "$owner" 30 "cat /proc/sys/net/netfilter/nf_conntrack_max" | first_line)
  fill_to $((max * 95 / 100)) | tee -a "$out"
  for k in 1 2 3; do
    owner=$(owner_nat)
    ./run.sh "$t-$BUILD-ctdump-$k" MODE=up PROCS=1 STREAMS=16 DURATION=40 PING=1 > "$log" 2>&1 &
    local run=$!
    load=$(wait_load "$log") || return 1
    if ((k > 1)); then
      sleep_to $((load + 10))
      on "$owner" 300 "echo table \$(cat /proc/sys/net/netfilter/nf_conntrack_count); /usr/bin/time -f 'conntrack -L: %e s elapsed, %U s user, %S s system, %M KB max RSS' conntrack -L 2>&1 > /dev/null | grep -v 'flow entries' | tail -2" | tee -a "$out"
    fi
    wait $run
    brief "$t-$BUILD-ctdump-$k"
  done
  clear_all | tee -a "$out"
}

# upgrade: the in-place self-update under traffic. BIG idle connections, then UP_LEN seconds of light TCP with pings,
# while the operator pins the new release with terraform apply once the load starts (upgrade-watch.txt says when).
# Every 10 s, both NATs' table, copy, release and readiness, from SSM, which skips a NAT while it reboots.
upgrade() {
  fill_to "$BIG"
  ready_wait 300 || return 1
  local log=/tmp/regress-run.log load nat w="$OUT/upgrade-watch.txt"
  idle_server
  say "idle connections: opened $(idle_open up "${IDLE:-500}"), before: $(idle_check up 0)" | tee -a "$w"
  ./run.sh "$t-$BUILD-upgrade" MODE=up PROCS=1 STREAMS=16 RATE="$LIGHT" DURATION="${UP_LEN:-1200}" PING=1 POLL=100ms > "$log" 2>&1 &
  local run=$!
  load=$(wait_load "$log") || return 1
  say "upgrade: load at $(date -u -d "@$load" +%T), pin the release now" | tee -a "$w"
  while kill -0 $run 2> /dev/null; do
    for nat in "$NAT_A" "$NAT_B"; do
      echo "$(date -u +%T) $nat $( [[ $nat == $(owner_nat) ]] && echo owner || echo standby) $(on "$nat" 20 'echo table $(cat /proc/sys/net/netfilter/nf_conntrack_count) external $(timeout 5 conntrackd -C /var/lib/natpair/conntrackd.conf -s 2>/dev/null | tr -s " \t\n" " " | grep -o "cache external: current active connections: [0-9]*" | grep -o "[0-9]*$") up $(cut -d" " -f1 /proc/uptime) $(journalctl -u natpair -o cat | grep "\"health round\"" | tail -1 | grep -o -E "\"(ready|healthy|serving|release|copied_connections|peer_tracked_connections)\":[^,}]*" | tr "\n" " ")' 2> /dev/null | head -1)" >> "$w"
    done
    sleep 10
  done
  wait $run
  say "idle connections after: $(idle_check up 1)" | tee -a "$w"
  idle_stop up
  brief "$t-$BUILD-upgrade"
  for nat in "$NAT_A" "$NAT_B"; do
    { echo "== $nat"; on "$nat" 60 "journalctl -u natpair -o short-iso-precise --since @$((load - 30)) | grep -E 'update|ownership acquired|forwarding open|ownership session ended|copied connections|requesting a full copy|handoff step|lease|incomplete|not answering' | cut -c1-300 | tail -40; journalctl --list-boots | tail -3"; } >> "$OUT/upgrade-journal.txt" 2>&1
  done
  cat "$OUT/upgrade-journal.txt"
}

# EXPECT_RELEASE: refuse to run unless both NATs report that release, so a job queued behind a failed upgrade doesn't
# test the old build under the new build's name.
if [[ -n ${EXPECT_RELEASE:-} ]]; then
  for nat in "$NAT_A" "$NAT_B"; do
    got=$(on "$nat" 60 "journalctl -u natpair -o cat | grep '\"health round\"' | tail -1 | grep -o '\"release\":\"[^\"]*\"'" | head -1)
    [[ $got == "\"release\":\"$EXPECT_RELEASE\"" ]] || { say "$nat reports $got, not $EXPECT_RELEASE: not running"; exit 1; }
  done
fi
receiver_firewall
for c in ${CASES:-info handover kill blackhole resync full flood}; do
  say "=== $c"
  case $c in
    kill) kill_owner ;;
    resync) resync_churn ;;
    clear) clear_all ;;
    *) "$c" ;;
  esac
done
say "=== done"
