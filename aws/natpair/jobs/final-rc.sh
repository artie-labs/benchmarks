#!/bin/bash
# Final release candidate (natpair bench/final: #9 #10 #11 #12 #15 #16 #14 #17 on master), one pass per NAT type.
# The blackhole fail-over check is jobs/fix-failover.sh, queued separately. Queue sections as separate jobs (prepend
# CASES=...) so results sync to the bucket after each. CASES picks and orders the sections, all by default:
#   info       kernel, binary, release, services, threaded NAPI and interrupts on both NATs
#   smoke      20 s of TCP and 20 s of 3,000 connections a second
#   handover   3 planned handovers at 2 Gbps (`natpair maintenance` 20 s in, `natpair resume` after). Each run's
#              irq.txt and threaded.txt show the new owner's interrupt layout and threaded NAPI
#   sat        TCP as fast as 32 flows go and TCP with 88-byte segments from 64 flows, 60 s, 3 rounds
#   udp        64-byte UDP at 800k and 1.2M packets a second, 60 s, 3 rounds. After each run, the owner's shared ENI
#              ring, receive-thread nice values and XDP program, once the guard has had time to clear
#   churn      3,000 connections a second, 3 consecutive 60 s runs, then 120 s with a forced full copy 60 s in
#   flood      1M pps UDP flood of the owner's own address while it forwards TCP at TCP_CAP, 3 rounds
#   probe      SYN and ACK probes from the receiver, then 3 ACK bursts to a worker port on the shared address
#   congested  `natpair maintenance` 20 s into 64-byte UDP at 1.2M pps (the guard engaged on the owner)
#   cost       CPU per packet below saturation: TCP at 8 Gbps (large) or 4 (medium) and UDP at 400k or 300k pps,
#              45 s, NATs sampled once a second, 3 rounds
BUILD=${BUILD:-final}
. ./lib.sh
t=$NAT_INSTANCE_TYPE

# after_clear <run name>: waits for the guard to clear, then records the owner's shared ENI state.
after_clear() {
  sleep 10
  {
    echo "== $1 $(date -u +%T) owner $(owner_nat)"
    on "$(owner_nat)" 60 'dev=$(ip -o -4 addr show | awk -v ip='"$(shared_private_ip)"' '\''$4 ~ "^"ip"/" {print $2}'\'')
      echo "shared dev $dev"; ethtool -g "$dev" | awk "/Current hardware/ {c=1} c && /^RX:/ {print \"ring rx \" \$2; exit}"
      ip -d link show dev "$dev" | grep -o "prog/xdp id [0-9]*" || echo "no xdp program"
      ps -eo ni,comm | grep "napi/$dev" | sort | uniq -c
      journalctl -u natpair -o cat --since "-4min" | grep -E "overload guard (engaged|cleared|limit)" | cut -c1-240 | tail -6'
  } >> "$RESULTS/$t-$BUILD-after-clear.txt" 2>&1
}

info() {
  for nat in "$NAT_A" "$NAT_B"; do
    echo "== $nat"
    on "$nat" 30 'uname -r; sha256sum /usr/local/bin/natpair | cut -c1-8; systemctl is-active natpair conntrackd irqbalance
      journalctl -u natpair -o cat | grep -m1 -o "\"release\":\"[^\"]*\""; grep -H . /sys/class/net/ens*/threaded
      for irq in $(grep -E "ens[0-9]+-Tx-Rx" /proc/interrupts | cut -d: -f1); do
        echo "$(grep "^ *$irq:" /proc/interrupts | awk "{print \$NF}") $(cat /proc/irq/$irq/effective_affinity_list)"; done'
  done > "$RESULTS/$t-$BUILD-info.txt" 2>&1
  cat "$RESULTS/$t-$BUILD-info.txt"
}

smoke() {
  ./run.sh "$t-$BUILD-smoke-tcp" MODE=up PROCS=1 STREAMS=16 DURATION=20 PING=1
  ./run.sh "$t-$BUILD-smoke-churn" MODE=churn CHURN_RATE=3000 DURATION=20
}

handover() {
  for k in 1 2 3; do
    wait_standby_ready || exit 1
    ./run.sh "$t-$BUILD-handover-$k" MODE=up PROCS=1 STREAMS=16 RATE=62.5M DURATION=60 HANDOVER_AT=20 PING=1
  done
}

sat() {
  for k in 1 2 3; do
    wait_standby_ready || exit 1
    ./run.sh "$t-$BUILD-tcp-$k" MODE=up PROCS=1 STREAMS=16 DURATION=60 PING=1
    wait_standby_ready || exit 1
    ./run.sh "$t-$BUILD-overload88-$k" MODE=up PROCS=2 STREAMS=16 MSS=88 DURATION=60 PING=1
  done
}

udp() {
  for k in 1 2 3; do
    for c in udp800k:6.4M udp1200k:9.6M; do
      wait_standby_ready || exit 1
      ./run.sh "$t-$BUILD-${c%%:*}-$k" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=${c##*:} DURATION=60 PING=1
      after_clear "$t-$BUILD-${c%%:*}-$k"
    done
  done
}

churn() {
  wait_standby_ready || exit 1
  for k in 1 2 3; do
    ./run.sh "$t-$BUILD-churn3000-$k" MODE=churn CHURN_RATE=3000 DURATION=60
  done
  local owner standby diag="$RESULTS/$t-$BUILD-resync-diag.txt"
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  ./run.sh "$t-$BUILD-resync" MODE=churn CHURN_RATE=3000 DURATION=120 > /tmp/resync-run.log 2>&1 &
  local run=$!
  sleep 60
  {
    echo "== before $(date -u +%T)"; on "$owner" 30 "cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max"
    on "$standby" 60 "conntrackd -C /var/lib/natpair/conntrackd.conf -n; echo requested a full copy"
    sleep 20
    echo "== after $(date -u +%T)"; on "$owner" 30 "cat /proc/sys/net/netfilter/nf_conntrack_count"
  } >> "$diag" 2>&1
  wait $run
  tail -3 /tmp/resync-run.log
  echo "owner before $owner, after $(owner_nat)" >> "$diag"
}

flood() {
  for k in 1 2 3; do
    wait_standby_ready || exit 1
    ./run.sh "$t-$BUILD-flood-udp-$k" MODE=up PROCS=1 STREAMS=16 RATE=$TCP_CAP DURATION=60 PING=1 FLOOD=udp FLOOD_PPS=1000000
  done
}

probe() {
  wait_standby_ready || exit 1
  local out="$RESULTS/$t-$BUILD-ext-probe.txt" owner shared own_a own_b ports=22,8080,40000,50000,61000,61500,62000,65000
  command -v nmap > /dev/null || dnf install -y -q nmap > /dev/null 2>&1
  owner=$(owner_nat)
  shared=$(shared_private_ip)
  own_a=$(aws ec2 describe-instances --instance-ids "$NAT_A" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  own_b=$(aws ec2 describe-instances --instance-ids "$NAT_B" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  {
    echo "owner $owner, shared $shared, nat a $own_a ($NAT_A), nat b $own_b ($NAT_B)"
    for k in 1 2 3; do
      for scan in sS sA; do
        for ip in "$shared" "$own_a" "$own_b"; do
          echo "== round $k nmap -$scan $ip"
          nmap -Pn -n -$scan -p "$ports" --reason -T4 --max-retries 1 "$ip" | grep -E "^[0-9]+/tcp"
        done
      done
      sleep 10
    done
    for k in 1 2 3; do
      sleep 15
      echo "== ACK burst round $k: 200 at 2000/s to $shared:40000, then 10 s at 50/s"
      python3 -I /opt/natpair-bench/ackburst.py "$shared" 40000 200 2000 10 50
    done
  } > "$out" 2>&1
  cat "$out"
}

congested() {
  wait_standby_ready || exit 1
  local old new
  old=$(owner_nat)
  ./run.sh "$t-$BUILD-congested-handover" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=9.6M DURATION=60 PING=1 HANDOVER_AT=20
  new=$(owner_nat)
  {
    echo "owner before $old, after $new"
    for nat in "$new" "$old"; do
      echo "== $nat"
      on "$nat" 60 "ip -d link show | grep -o 'prog/xdp id [0-9]*' | head -2; journalctl -u natpair -o cat --since '-4min' | grep -E 'maintenance|overload guard|forwarding open|ownership acquired|ownership session ended|handed over|turned on threaded' | cut -c1-300 | tail -14"
    done
  } > "$RESULTS/$t-$BUILD-congested-handover.txt" 2>&1
  cat "$RESULTS/$t-$BUILD-congested-handover.txt"
  after_clear "$t-$BUILD-congested-handover"
}

cost() {
  local tcp udp
  case $t in
    c7gn.large) tcp=250M udp=3.2M ;;
    *) tcp=125M udp=2.4M ;;
  esac
  wait_standby_ready || exit 1
  for k in 1 2 3; do
    ./run.sh "$t-$BUILD-cost-tcpfixed-$k" MODE=up PROCS=1 STREAMS=16 RATE=$tcp DURATION=45 POLL=1s
    ./run.sh "$t-$BUILD-cost-udpfixed-$k" MODE=udp LEN=64 PROCS=2 STREAMS=16 RATE=$udp DURATION=45 POLL=1s
  done
}

for c in ${CASES:-info smoke handover sat udp churn flood probe congested cost}; do
  echo "=== $c $(date -u +%T)"
  "$c"
done
echo "=== done $(date -u +%T)"
