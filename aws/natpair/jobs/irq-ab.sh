#!/bin/bash
# Is natpair#10 (interrupt spreading, irqbalance off) still needed with natpair#16 (threaded NAPI)? One pass per build
# and NAT type. Prepend BUILD=napi-only|napi-irq (names the runs) and SETTLE=<seconds to wait after the takeovers
# before recording the layout: 65 with irqbalance, so it has had a minute, 15 with #10's 5 s loop>. CASES picks and
# orders the sections, all by default:
#   info      kernel, binary, irqbalance, CPUs, queues per ENI, threaded NAPI, interrupt and napi/ thread layout
#   watch     starts box/irqwatch.sh on both NATs for WATCH seconds (default 2400), every 2 s, in the background
#   sat       TCP as fast as 32 flows go and TCP with 88-byte segments from 64 flows, 60 s, 3 rounds
#   takeover  3 takeovers (`natpair maintenance` on the owner, `natpair resume` once the other NAT owns), the layout
#             5 s after each and SETTLE s after the last, then one full-rate TCP run on the new owner
# The layouts and journal counts go to $RESULTS/<type>-<build>-layout.txt. Each run's summary has `placement`.
BUILD=${BUILD:?}
SETTLE=${SETTLE:-65}
WATCH=${WATCH:-2400}
CASES=${CASES:-info watch sat takeover}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
layout_file=$RESULTS/$t-$BUILD-layout.txt
# The generators have 2 vCPUs for c7gn.large NATs and 4 for c7gn.xlarge ones, so the larger pair gets more iperf3
# processes for the same flows.
case $t in
  c7gn.xlarge) TCP=(PROCS=2 STREAMS=8) SMALL=(PROCS=4 STREAMS=8) ;;
  *) TCP=(PROCS=1 STREAMS=16) SMALL=(PROCS=2 STREAMS=16) ;;
esac

layout_cmd='echo "irqbalance $(systemctl is-active irqbalance) $(systemctl is-enabled irqbalance 2>&1)"
  for irq in $(grep -E "ens[0-9]+-Tx-Rx" /proc/interrupts | cut -d: -f1); do
    echo "$(grep "^ *$irq:" /proc/interrupts | awk "{print \$NF}") $(cat /proc/irq/$irq/effective_affinity_list)"; done | paste -sd" "
  for pid in $(pgrep "^napi/"); do echo "$(cat /proc/$pid/comm)=$(ps -o psr= -p $pid | tr -d " ")"; done | paste -sd" "'

# layout <label>: both NATs' interrupt and receive thread layout, owner first.
layout() {
  local owner nat
  owner=$(owner_nat)
  {
    echo "== $1 $(date -u +%FT%TZ) owner $owner"
    for nat in "$owner" "$(other_nat "$owner")"; do
      echo "-- $nat"
      on "$nat" 30 "$layout_cmd"
    done
  } >> "$layout_file" 2>&1
}

info() {
  {
    echo "== info $(date -u +%FT%TZ) owner $(owner_nat)"
    for nat in "$NAT_A" "$NAT_B"; do
      echo "-- $nat"
      on "$nat" 30 'uname -r; nproc; sha256sum /usr/local/bin/natpair | cut -c1-8; systemctl is-active natpair conntrackd
        journalctl -u natpair -o cat | grep -m1 -o "\"release\":\"[^\"]*\""; grep -H . /sys/class/net/ens*/threaded
        for d in /sys/class/net/ens*; do echo "${d##*/} $(ethtool -l ${d##*/} | awk "/Current/ {c=1} c && /Combined/ {print \"queues \" \$2; exit}")"; done
        '"$layout_cmd"
    done
    echo "-- generator $(echo $GENERATORS | cut -d" " -f1)"
    on "$(echo $GENERATORS | cut -d" " -f1)" 30 'iperf3 --version | head -1; nproc'
  } >> "$layout_file" 2>&1
  cat "$layout_file"
}

watch() {
  local nat
  for nat in "$NAT_A" "$NAT_B"; do
    ssm_send "$nat" "$((WATCH + 120))" "aws s3 cp --only-show-errors s3://$BUCKET/box/irqwatch.sh /tmp/irqwatch.sh && env BUCKET=$BUCKET AWS_REGION=$AWS_REGION bash /tmp/irqwatch.sh $t-$BUILD $WATCH 2" > /dev/null
  done
  echo "irqwatch started on both NATs for $WATCH s"
}

sat() {
  for k in 1 2 3; do
    wait_standby_ready || exit 1
    ./run.sh "$t-$BUILD-tcp-$k" MODE=up "${TCP[@]}" DURATION=60 PING=1
    ./run.sh "$t-$BUILD-tcp88-$k" MODE=up "${SMALL[@]}" MSS=88 DURATION=60 PING=1
  done
}

takeover() {
  local k i old new since
  since=@$(date +%s)
  for k in 1 2 3; do
    wait_standby_ready || exit 1
    old=$(owner_nat)
    on "$old" 120 "natpair maintenance" > /dev/null || echo "natpair maintenance failed on $old"
    for ((i = 0; i < 60; i++)); do
      new=$(owner_nat)
      [[ $new != "$old" && $new != None ]] && break
      sleep 2
    done
    echo "takeover $k: $old -> $new at $(date -u +%T)"
    sleep 5
    layout "takeover $k +5s"
    on "$old" 60 "natpair resume" > /dev/null || echo "natpair resume failed on $old"
  done
  wait_standby_ready || exit 1
  sleep "$SETTLE"
  layout "after 3 takeovers +${SETTLE}s"
  {
    echo "== journal since $since"
    for nat in "$NAT_A" "$NAT_B"; do
      echo "-- $nat"
      on "$nat" 30 "journalctl -u natpair -o cat --since '$since' | grep -cE 'lease store unreachable' | sed 's/^/lease_store_unreachable /'
        journalctl -u natpair -o cat --since '$since' | grep -cE 'failed to resolve probe receiver|shared Elastic IP not working yet' | sed 's/^/dns_or_probe_timeout /'
        journalctl -u natpair -o cat --since '$since' | grep -cE 'ownership acquired' | sed 's/^/ownership_acquired /'
        journalctl -u natpair -o cat --since '$since' | grep -E 'spread network queue|turned on threaded' | cut -c1-200"
    done
  } >> "$layout_file" 2>&1
  ./run.sh "$t-$BUILD-tko-tcp" MODE=up "${TCP[@]}" DURATION=60 PING=1
  layout "after the post-takeover run"
}

for c in $CASES; do
  echo "== $c $(date -u +%T)"
  "$c"
done
