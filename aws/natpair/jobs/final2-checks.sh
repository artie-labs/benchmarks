#!/bin/bash
# Final release candidate, round 2 (natpair bench/final2: #11 #12 #15 #16 #14 #17 on master with #9): the checks
# added for this round. The rest of the round runs jobs/final-rc.sh and jobs/fix-failover.sh with BUILD=final2.
# Queue sections as separate jobs (prepend CASES=...). CASES picks and orders them:
#   peerroute  #11. During 3,000 connections a second, 3 rounds 62 s apart (the daemon warns at most once a minute):
#              delete the owner's route to the peer, time how long the daemon takes to put it back and record its
#              warning, then count 15 s of conntrackd copies (UDP port 3780) and IP fragments leaving each of the
#              owner's interfaces
#   fullkill   #12. 15,000 connections a second fill the owner's connection table, then the owner's daemon is killed
#              (SIGKILL) and kept down. The standby must take over once and keep forwarding. 3 rounds
#   crash      #17. During 64-byte UDP at 1.2M packets a second, once the guard limits (ring raised, receive threads
#              at nice -10), SIGKILL the owner's daemon. systemd restarts it within about 1 s, and it must put the
#              ring and the threads back. 3 rounds, then 1 with the off switch created just before the kill
#   budget     #17. A 30 s flood at 1.2M packets a second measures the cut budget. Then 3 runs of 25 s at 1.2M
#              followed by 45 s at 15% above that budget: the guard must raise its budget and clear. STEP_PCT (115),
#              STEP_LEN (45 s), RUNS (3) and TAG change the step's rate, length, the number of runs and the names
#   sustained  The #15 A/B: one 10-minute run of 64-byte UDP at 1.2M packets a second (with jobs/final-rc.sh's udp
#              section for the 60 s runs at 800k and 1.2M)
#   tcp1       The #15 A/B: one 60 s run of TCP as fast as 32 flows go
BUILD=${BUILD:-final2}
. ./lib.sh
t=$NAT_INSTANCE_TYPE

# private_ip <instance>
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

# sleep_to <epoch seconds>
sleep_to() {
  local d=$(($1 - $(date +%s)))
  ((d > 0)) && sleep "$d"
  return 0
}

peerroute() {
  wait_standby_ready || exit 1
  local owner peer own out="$RESULTS/$t-$BUILD-peerroute.txt" log=/tmp/peerroute-run.log load
  owner=$(owner_nat)
  peer=$(private_ip "$(other_nat "$owner")")
  own=$(private_ip "$owner")
  ./run.sh "$t-$BUILD-peerroute" MODE=churn CHURN_RATE=3000 DURATION=210 > "$log" 2>&1 &
  local run=$!
  load=$(wait_load "$log") || exit 1
  sleep_to $((load + 10))
  {
    echo "owner $owner ($own), peer $peer"
    for k in 1 2 3; do
      sleep_to $((load + 10 + 62 * (k - 1)))
      echo "== round $k $(date -u +%T)"
      on "$owner" 60 "pri=\$(ip -o -4 addr show | awk '\$4 ~ /^$own\\// {print \$2}')
        sh=\$(ip -o -4 addr show | awk '\$4 ~ /^$(shared_private_ip)\\// {print \$2}')
        echo primary \$pri shared \$sh
        echo before: \$(ip -4 route show $peer/32)
        t0=\$(date +%s.%N); ip route del $peer/32; echo deleted at \$(date -u +%T.%N | cut -c1-12)
        restored=
        for i in \$(seq 100); do
          if ip -4 route show $peer/32 | grep -q \"dev \$pri .*src $own\"; then
            restored=\$(awk -v a=\$t0 -v b=\$(date +%s.%N) 'BEGIN {printf \"%.1f\", b - a}'); break
          fi
          sleep 0.1
        done
        echo restored after \${restored:-never} s: \$(ip -4 route show $peer/32)
        echo route get: \$(ip -4 route get $peer | head -1)
        journalctl -u natpair -o cat --since '-20s' | grep 'route to the peer' | cut -c1-240
        iptables -w 5 -t mangle -N BENCHCOUNT 2> /dev/null; iptables -w 5 -t mangle -F BENCHCOUNT
        for d in \$pri \$sh; do
          iptables -w 5 -t mangle -A BENCHCOUNT -o \$d -p udp --dport 3780
          iptables -w 5 -t mangle -A BENCHCOUNT -o \$d -f
        done
        iptables -w 5 -t mangle -I POSTROUTING 1 -j BENCHCOUNT
        frags() { awk '/^Ip:/ {if (!h) {for (i = 1; i <= NF; i++) if (\$i == \"FragCreates\") c = i; h = 1} else print \$c}' /proc/net/snmp; }
        frag0=\$(frags)
        sleep 15
        frag1=\$(frags)
        iptables -w 5 -t mangle -L BENCHCOUNT -v -x -n | tail -n +3
        iptables -w 5 -t mangle -D POSTROUTING -j BENCHCOUNT; iptables -w 5 -t mangle -F BENCHCOUNT; iptables -w 5 -t mangle -X BENCHCOUNT
        echo IP FragCreates in 15 s: \$((frag1 - frag0))"
    done
  } > "$out" 2>&1
  wait $run
  tail -3 "$log" >> "$out"
  cat "$out"
}

fullkill() {
  local k owner standby out log load
  for k in 1 2 3; do
    wait_standby_ready || exit 1
    owner=$(owner_nat)
    standby=$(other_nat "$owner")
    out="$RESULTS/$t-$BUILD-fullkill-$k.txt"
    log=/tmp/fullkill-run.log
    ./run.sh "$t-$BUILD-fullkill-$k" MODE=churn CHURN_RATE=15000 DURATION=120 > "$log" 2>&1 &
    local run=$!
    load=$(wait_load "$log") || exit 1
    {
      echo "owner $owner, standby $standby, load at $(date -u -d "@$load" +%T)"
      # Wait until the owner's table is full: at least 99% of its limit.
      for ((i = 0; i < 20; i++)); do
        sleep_to $((load + 15 + 3 * i))
        read -r count max <<< "$(on "$owner" 30 'echo $(cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max)')"
        echo "$(date -u +%T) table $count of $max"
        ((count * 100 >= max * 99)) && break
      done
      sleep 5
      on "$owner" 30 "echo table \$(cat /proc/sys/net/netfilter/nf_conntrack_count) at the kill; journalctl -u natpair -o cat --since '-60s' | grep -E 'connection table is (nearly )?full|ownership session ended' | cut -c1-200 | tail -4
        systemctl kill -s SIGKILL natpair; sleep 0.3; systemctl stop natpair; echo killed and stopped at \$(date -u +%T.%N | cut -c1-12); systemctl is-active natpair"
      for ((i = 0; i < 60; i++)); do
        [[ $(owner_nat) == "$standby" ]] && { echo "shared ENI on $standby at $(date -u +%T)"; break; }
        sleep 2
      done
    } > "$out" 2>&1
    wait $run
    {
      tail -3 "$log"
      echo "== new owner $standby, journal since the kill"
      on "$standby" 60 "journalctl -u natpair -o cat --since '-150s' | grep -E 'ownership acquired|forwarding open|ownership session ended|takeover|aborted|stepped down|connection table is full|health probe failed because' | cut -c1-260 | tail -16
        echo acquired: \$(journalctl -u natpair -o cat --since '-150s' | grep -c 'ownership acquired') sessions ended: \$(journalctl -u natpair -o cat --since '-150s' | grep -c 'ownership session ended')"
      echo "owner after the run: $(owner_nat)"
      on "$owner" 60 "systemctl start natpair; sleep 2; systemctl is-active natpair"
    } >> "$out" 2>&1
    cat "$out"
  done
}

# crash_round <name> <off: 0|1>
crash_round() {
  local name=$1 off=$2 owner shared out="$RESULTS/$t-$BUILD-$1.txt" log=/tmp/crash-run.log load
  wait_standby_ready || exit 1
  owner=$(owner_nat)
  shared=$(shared_private_ip)
  ./run.sh "$t-$BUILD-$name" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M DURATION=32 PING=1 > "$log" 2>&1 &
  local run=$!
  load=$(wait_load "$log") || exit 1
  sleep_to $((load + 14))
  {
    echo "owner $owner, load at $(date -u -d "@$load" +%T), flood ends $(date -u -d "@$((load + 32))" +%T), off switch $off"
    # 14 s into the flood: wait for the guard to limit, kill the daemon about 26 s in, then sample the ring and
    # the receive threads' nice values every 0.2 s for 12 s. The flood ends 32 s in.
    on "$owner" 90 "dev=\$(ip -o -4 addr show | awk '\$4 ~ /^$shared\\// {print \$2}')
      ring() { ethtool -g \$dev | awk '/Current hardware/ {c=1} c && /^RX:/ {print \$2; exit}'; }
      nices() { ps -eo ni,comm | awk -v d=\"napi/\$dev-\" 'index(\$2, d) == 1 {print \$1}' | sort | uniq -c | tr -s ' ' | tr '\n' ' '; }
      for i in \$(seq 50); do [[ \$(ring) -gt 1024 ]] && nices | grep -q -- '-10' && break; sleep 0.2; done
      echo engaged state \$(date -u +%T.%N | cut -c1-12): ring \$(ring), nice \$(nices), \$(ip -d link show dev \$dev | grep -o 'prog/xdp id [0-9]*' || echo no xdp), record \$(cat /var/lib/natpair/overload-guard-ring 2> /dev/null || echo none)
      sleep_s=\$(( $((load + 26)) - \$(date +%s) )); (( sleep_s > 0 )) && sleep \$sleep_s
      pid=\$(systemctl show -p MainPID --value natpair)
      [[ $off == 1 ]] && touch /var/lib/natpair/overload-guard-off
      kill -9 \$pid; t0=\$(date +%s.%N); echo killed \$pid at \$(date -u +%T.%N | cut -c1-12)
      for i in \$(seq 60); do
        now=\$(systemctl show -p MainPID --value natpair)
        echo \"  +\$(awk -v a=\$t0 -v b=\$(date +%s.%N) 'BEGIN {printf \"%.1f\", b - a}') s pid \$now ring \$(ring) nice \$(nices)\$(ip -d link show dev \$dev | grep -o ' prog/xdp' || true) record \$( [[ -e /var/lib/natpair/overload-guard-ring ]] && echo yes || echo no)\"
        sleep 0.2
      done
      journalctl -u natpair -o cat --since '-20s' | grep -E 'overload guard|Started|release' | cut -c1-220 | tail -10
      [[ $off == 1 ]] && rm -f /var/lib/natpair/overload-guard-off && echo removed the off switch
      true"
  } > "$out" 2>&1
  wait $run
  tail -2 "$log" >> "$out"
  sleep 10
  {
    echo "== both NATs 10 s after the run"
    for nat in "$NAT_A" "$NAT_B"; do
      on "$nat" 60 "echo $nat; for d in \$(ls /sys/class/net | grep ^ens); do echo \$d ring \$(ethtool -g \$d | awk '/Current hardware/ {c=1} c && /^RX:/ {print \$2; exit}') \$(ip -d link show dev \$d | grep -o 'prog/xdp id [0-9]*' || echo no-xdp) nice \$(ps -eo ni,comm | awk -v d=\"napi/\$d-\" 'index(\$2, d) == 1 {print \$1}' | sort | uniq -c | tr -s ' ' | tr '\n' ' '); done; ls /var/lib/natpair/overload-guard-* 2> /dev/null"
    done
    echo "owner after: $(owner_nat)"
  } >> "$out" 2>&1
  cat "$out"
}

crash() {
  for k in 1 2 3; do crash_round "crash-$k" 0; done
  crash_round crash-offswitch 1
}

# guard_log <instance> <since>: the owner's guard lines since a time.
guard_log() {
  on "$1" 60 "journalctl -u natpair -o cat --since '$2' | grep -E 'overload guard (attached|engaged|lowered|raised|cleared|stood)' | sed -E 's/\"(level|interface)\":\"[^\"]*\",?//g'"
}

budget() {
  wait_standby_ready || exit 1
  local pct=${STEP_PCT:-115} len=${STEP_LEN:-45} runs=${RUNS:-3} tag=${TAG:-budget}
  local owner since out="$RESULTS/$t-$BUILD-$tag.txt" cut queues total rate2 k
  owner=$(owner_nat)
  since=$(date -u '+%F %T')
  ./run.sh "$t-$BUILD-$tag-cal" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M DURATION=30 PING=1 > /tmp/budget-run.log 2>&1
  {
    echo "== calibration on $owner"
    guard_log "$owner" "$since" | tee /tmp/budget-cal.txt
    # The last budget the flood left, per CPU, and how many receive queues the shared ENI spreads it over.
    cut=$(grep -E 'lowered|engaged' /tmp/budget-cal.txt | grep -o '"budget_pps_per_cpu":[0-9]*' | tail -1 | cut -d: -f2)
    queues=$(on "$owner" 30 "ls -d /sys/class/net/\$(ip -o -4 addr show | awk '\$4 ~ /^$(shared_private_ip)\\// {print \$2}')/queues/rx-* | wc -l")
    if [[ -z $cut || -z $queues ]]; then
      echo "no budget from the calibration run"
      cat "$out"
      exit 1
    fi
    queues=${queues//[^0-9]/}
    total=$((cut * queues))
    # pct% of the cut budget, over 64 flows of 64-byte datagrams (512 bits each).
    rate2=$((total * pct / 100 * 512 / 64))
    echo "cut budget $cut per CPU x $queues queues = $total pps; step to $((total * pct / 100)) pps for $len s (RATE2=$rate2 bits a flow)"
  } > "$out" 2>&1
  for ((k = 1; k <= runs; k++)); do
    wait_standby_ready || exit 1
    owner=$(owner_nat)
    since=$(date -u '+%F %T')
    ./run.sh "$t-$BUILD-$tag-$k" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M PATTERN=step STEP_AT=25 RATE2=$rate2 \
      DURATION=$((25 + len)) PING=1 > /tmp/budget-run.log 2>&1
    {
      echo "== run $k on $owner: $(grep -o 'load at [0-9TZ:-]*' /tmp/budget-run.log | head -1), step 25 s in"
      tail -2 /tmp/budget-run.log
      guard_log "$owner" "$since"
    } >> "$out" 2>&1
  done
  cat "$out"
}

sustained() {
  wait_standby_ready || exit 1
  ./run.sh "$t-$BUILD-sustained1200k" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M DURATION=600 PING=1 POLL=100ms
}

tcp1() {
  wait_standby_ready || exit 1
  ./run.sh "$t-$BUILD-tcp-ab" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1
}

for c in ${CASES:-peerroute fullkill crash budget}; do
  echo "=== $c $(date -u +%T)"
  "$c"
done
echo "=== done $(date -u +%T)"
