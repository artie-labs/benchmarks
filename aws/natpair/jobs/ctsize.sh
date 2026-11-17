#!/bin/bash
# Connection table sizing (RESULTS.md, "Connection table sizing"): what each natpair max_connections costs and holds.
# hold (see hold/) opens idle established TCP connections through the owner from every generator address, so the
# owner's table holds them and conntrackd copies them to the standby, as with workers' idle keep-alive connections.
# Sizes are set by hand on the running NATs with box/ctnat.sh: the same settings natpair bootstrap makes at boot.
#
# Sections (CASES, run in the order given):
#   base     at 262,144: memory on both NATs with an empty table, 20 s of TCP as fast as 16 flows go, churn at
#            1,000 new connections a second
#   full     at 262,144: idle connections past the limit, then churn into the full table
#   ceiling  churn alone for 60 s at each of CEIL_RATES (new connections a second in total) at size CEIL_SIZE
#   sweep    for each of SIZES: fill to 95% (stopping early if either NAT's MemAvailable falls below MIN_AVAIL_MB),
#            memory, TCP and churn near full, a full copy to a restarted standby conntrackd, then a takeover
#   refill   clears every hold connection, then fills to 95% of REFILL_SIZE
#   bufab    at the current fill: a full copy to a restarted standby with conntrackd's UDP socket buffers raised to
#            BUFFER bytes on both NATs (not natpair's configuration), then back to the defaults
#   clear    resets every hold connection, then memory with an empty table at the current size
#
# For builds with natpair's copy fixes (natpair bench/ctfix, "Copy completeness and sizing fixes" in RESULTS.md):
#   ports    with an empty table, PORTS_HELD idle connections to one receiver port, then checks the owner's
#            shared-port warning and the health rounds' shared_ports_used, then closes them and checks the line
#            for dropping back under
#   fix      at FIX_SIZE (resized with ctnat.sh resizefix unless it is natpair's default, 524,288): fill to 95%,
#            memory, TCP with one hash bucket per entry and with a quarter (BUCKET_ROUNDS rounds each), a full copy
#            to a restarted standby conntrackd and to a rebooted standby, each timed until the standby is ready,
#            then a takeover
# FILL_RATE sets hold's connections a second in total, TAG the run names.
CASES=${CASES:-base}
. ./lib.sh
t=$NAT_INSTANCE_TYPE
TAG=${TAG:-ct}
FILL_RATE=${FILL_RATE:-20000}
SIZES=${SIZES:-262144 524288 1048576 2097152 4194304}
CEIL_SIZE=${CEIL_SIZE:-262144}
CEIL_RATES=${CEIL_RATES:-6000 8000 10000}
MIN_AVAIL_MB=${MIN_AVAIL_MB:-600}
OUT=$RESULTS/ctsize-$t
mkdir -p "$OUT"
# Connections opened so far from each generator address. It persists across jobs.
STATE=/root/ctsize-opened
# Connection indexes per generator address: address g uses g * 2,000,000 onward (see hold's -from).
PER_ADDRESS=2000000
receiver_ip=$(ip -4 -o route get 10.40.0.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
shared=$(shared_private_ip)
read -r -a gens <<< "$GENERATORS"
addrs=()
for n in "${!gens[@]}"; do
  v=GEN_ADDRS_$n
  read -r -a a <<< "${!v}"
  addrs+=("${a[@]}")
done

say() { echo "$(date -u +%T) $*"; }
first_line() { head -1 | tr -d '[:space:]'; }

# ctnat <nat> <timeout> <args>: runs box/ctnat.sh on a NAT.
ctnat() {
  local nat=$1 timeout=$2
  shift 2
  on "$nat" "$timeout" "aws s3 cp --only-show-errors --region $AWS_REGION s3://$BUCKET/box/ctnat.sh /tmp/ctnat.sh && env BUCKET=$BUCKET AWS_REGION=$AWS_REGION bash /tmp/ctnat.sh $*"
}

avail_mb() {
  local mb i
  for i in 1 2 3; do
    mb=$(on "$1" 30 "awk '\$1 == \"MemAvailable:\" {print int(\$2 / 1024)}' /proc/meminfo" | first_line)
    [[ -n $mb ]] && break
  done
  echo "${mb:-0}"
}
table_count() { on "$1" 30 "cat /proc/sys/net/netfilter/nf_conntrack_count" | first_line; }
external_count() {
  on "$1" 30 "timeout 5 conntrackd -C /var/lib/natpair/conntrackd.conf -s | tr -s ' \t\n' ' ' | grep -o 'cache external: current active connections: [0-9]*' | grep -o '[0-9]*\$'" | first_line
}

# ready_wait <seconds>: waits until the standby's latest health round says "ready":true, for at most that long.
ready_wait() {
  local i standby
  for ((i = 0; i < $1; i += 10)); do
    standby=$(other_nat "$(owner_nat)")
    if on "$standby" 60 "journalctl -u natpair -o cat | grep '\"health round\"' | tail -1" | grep -q '"ready":true'; then
      say "standby $standby ready"
      return 0
    fi
    sleep 7
  done
  say "standby $standby not ready after $1 s"
  return 1
}

# receiver_firewall: the security group leaves the churn ports open to any address, so connection tracking doesn't
# limit churn (see tf/network.tf). Only the test VPC may reach them.
receiver_firewall() {
  command -v iptables > /dev/null || dnf install -y -q iptables-nft > /dev/null 2>&1
  iptables -t raw -C PREROUTING -p tcp --dport 6000:6063 ! -s 10.40.0.0/16 -j DROP 2> /dev/null ||
    iptables -t raw -I PREROUTING -p tcp --dport 6000:6063 ! -s 10.40.0.0/16 -j DROP
}

start_server() {
  iptables -t raw -C PREROUTING -p tcp --dport 7000:7255 -j DROP 2> /dev/null ||
    iptables -t raw -I PREROUTING -p tcp --dport 7000:7255 -j DROP
  pgrep -x hold > /dev/null || { nohup ./bin/hold -serve -peer "$shared" -ports 7000-7255 >> /root/hold-serve.log 2>&1 & }
}

# gen_cmd <generator index> <from> <count> <rate> <open|close>: the command that runs hold from each of a
# generator's addresses at once, and prints the totals.
gen_cmd() {
  local n=$1 from=$2 count=$3 rate=$4 mode=$5 v=GEN_ADDRS_$1 k g0 cmd flag=
  read -r -a a <<< "${!v}"
  g0=$((n * ${#a[@]}))
  [[ $mode == close ]] && flag=-close
  cmd="rm -f /tmp/hold-*.json
command -v iptables > /dev/null || dnf install -y -q iptables-nft > /dev/null 2>&1
iptables -t raw -C PREROUTING -p tcp -s $receiver_ip --sport 7000:7255 -j DROP 2> /dev/null || iptables -t raw -I PREROUTING -p tcp -s $receiver_ip --sport 7000:7255 -j DROP
aws s3 cp --only-show-errors --region $AWS_REGION s3://$BUCKET/box/bin/hold /tmp/hold && chmod +x /tmp/hold"
  for k in "${!a[@]}"; do
    cmd+="
/tmp/hold -target $receiver_ip -source ${a[k]} -ports 7000-7255 -from $(((g0 + k) * PER_ADDRESS + from)) -count $count -rate $rate $flag -out /tmp/hold-$k.json &"
  done
  cmd+="
wait
python3 -I -c 'import json, glob
r = [json.load(open(f)) for f in sorted(glob.glob(\"/tmp/hold-*.json\"))]
print(\" \".join(\"%s=%d\" % (k, sum(x.get(k, 0) for x in r)) for k in (\"established\", \"syns\", \"resent\", \"syn_acks\", \"resets\", \"send_errors\")), \"seconds=%.1f\" % max(x[\"seconds\"] for x in r))'"
  echo "$cmd"
}

# holds <open|close> <from> <count>: runs hold on every generator address at once, count connections each.
holds() {
  local mode=$1 from=$2 count=$3 rate ids=() n timeout
  rate=$((FILL_RATE / ${#addrs[@]}))
  [[ $mode == close ]] && rate=$((rate * 2))
  timeout=$((count / rate * 2 + 60))
  for n in "${!gens[@]}"; do
    ids+=("$(ssm_send "${gens[n]}" "$timeout" "$(gen_cmd "$n" "$from" "$count" "$rate" "$mode")")")
  done
  for n in "${!gens[@]}"; do
    echo "  gen $n: $(ssm_wait "${ids[n]}" "${gens[n]}" | head -1)"
  done
}

# fill_to <entries>: opens new hold connections until the owner's table holds that many. Counting the table instead
# of the connections opened makes up for connections an earlier takeover lost.
fill_to() {
  local opened chunk=0 owner standby a b count previous=-1
  opened=$(cat "$STATE" 2> /dev/null || echo 0)
  start_server
  while true; do
    owner=$(owner_nat)
    standby=$(other_nat "$owner")
    count=$(table_count "$owner")
    ((${count:-0} * 100 >= $1 * 99)) && break
    # A full table takes no more: stop once a round adds under a tenth of what it opened.
    if ((previous >= 0 && (count - previous) * 10 < chunk * ${#addrs[@]})); then
      say "the table stopped growing at $count"
      break
    fi
    previous=${count:-0}
    a=$(avail_mb "$owner")
    b=$(avail_mb "$standby")
    if ((a < MIN_AVAIL_MB || b < MIN_AVAIL_MB)); then
      say "fill stopped at a table of $count: MemAvailable owner $a MB, standby $b MB"
      return 1
    fi
    chunk=$((($1 - count + ${#addrs[@]} - 1) / ${#addrs[@]}))
    ((chunk > 65536)) && chunk=65536
    say "fill: table $count, opening $((chunk * ${#addrs[@]})) (MemAvailable owner $a MB, standby $b MB)"
    holds open "$opened" "$chunk"
    opened=$((opened + chunk))
    echo "$opened" > "$STATE"
  done
  say "filled: owner table $count"
}

clear_all() {
  local opened
  opened=$(cat "$STATE" 2> /dev/null || echo 0)
  if ((opened > 0)); then
    # Twice: a few resets get lost.
    say "closing $((opened * ${#addrs[@]})) hold connections"
    holds close 0 "$opened"
    holds close 0 "$opened"
  fi
  echo 0 > "$STATE"
  # A reset entry leaves the table after 10 s, and the kernel's cleanup can lag behind that.
  sleep 30
  say "owner table $(table_count "$(owner_nat)")"
}

resize() {
  local owner standby
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  say "resize to $1: standby $standby: $(ctnat "$standby" 300 resize "$1" | head -1)"
  say "resize to $1: owner $owner: $(ctnat "$owner" 300 resize "$1" | head -1)"
  ready_wait 240
}

snap() {
  local owner standby nat
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  for nat in "$owner" "$standby"; do
    { echo "== $1 $nat $(date -u +%T)"; ctnat "$nat" 900 snap; } | tee -a "$OUT/snaps.txt"
  done
}

events() {
  local nat
  for nat in "$NAT_A" "$NAT_B"; do
    { echo "== events $1 $nat (owner now $(owner_nat))"; ctnat "$nat" 60 events "$2"; } | tee -a "$OUT/events.txt"
  done
}

samplers() {
  local nat
  for nat in "$NAT_A" "$NAT_B"; do ctnat "$nat" 60 "$@" > /dev/null; done
}

result_of() { ls -t "$RESULTS"/*-"$1".json 2> /dev/null | head -1; }

churn_brief() {
  python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1]))
c = [h["churn"] for h in s["hosts"].values() if h.get("churn")]
o = s["hosts"].get(s["meta"]["owner"], {})
failed = {}
for x in c:
    for k, v in (x.get("failed") or {}).items():
        failed[k] = failed.get(k, 0) + v
print(s["meta"]["run"], "started", sum(x.get("started", 0) for x in c), "skipped", sum(x.get("skipped", 0) for x in c),
      "completed/s %.0f" % sum(x.get("completed_per_second", 0) for x in c), "failed", failed,
      "p50", [x.get("latency_ms_p50") for x in c], "p99", [x.get("latency_ms_p99") for x in c],
      "max", [x.get("latency_ms_max") for x in c], "conntrack", o.get("conntrack"),
      "busy_cores", (o.get("cpu") or {}).get("busy_cores"))' "$(result_of "$1")" | tee -a "$OUT/runs.txt"
}

tcp_run() {
  ./run.sh "$t-$TAG-$1-tcp" MODE=up PROCS=2 STREAMS=8 DURATION=20 PRE=3 POST=3 | tail -1 | tee -a "$OUT/runs.txt"
}

churn_run() {
  ./run.sh "$t-$TAG-$1-churn$2" MODE=churn CHURN_RATE="$2" DURATION="${3:-30}" PRE=3 POST=3 > /dev/null
  churn_brief "$t-$TAG-$1-churn$2"
}

base() {
  resize 262144
  snap empty
  tcp_run empty
  churn_run empty 1000
}

full() {
  local t0
  resize 262144
  t0=$(date +%s)
  fill_to $((262144 * 103 / 100))
  sleep 10
  snap full
  churn_run full 200
  events full "$t0"
  clear_all
}

ceiling() {
  local rate t0
  resize "$CEIL_SIZE"
  t0=$(date +%s)
  for rate in $CEIL_RATES; do
    churn_run "ceil$((CEIL_SIZE / 1024))k" "$rate" 60
    sleep 35
  done
  events "ceiling$CEIL_SIZE" "$t0"
}

# copy_wait <standby> <owner table>: waits until the standby's copy holds 98% of the owner's table, or grows by less
# than 0.5% of the table in 30 s (live copies of new connections keep it creeping), and sets got to the copy's size.
copy_wait() {
  local i last=-1000000000 since
  since=$(date +%s)
  for ((i = 0; i < 300; i++)); do
    got=$(external_count "$1")
    [[ -n $got ]] && ((got * 100 >= $2 * 98)) && return 0
    if (((${got:-0} - last) * 200 > $2)); then
      last=${got:-0}
      since=$(date +%s)
    elif (($(date +%s) - since >= 30)); then
      say "copy stopped growing at $got of $2"
      return 1
    fi
    sleep 2
  done
}

# resync <label>: restarts the standby's conntrackd, which asks the owner for its whole table, and samples both
# NATs until the copy holds 98% of the owner's table.
resync() {
  local owner standby target t0 got
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  target=$(table_count "$owner")
  samplers sample "$t-$TAG-$1-resync" 1200
  sleep 3
  t0=$(date +%s)
  on "$standby" 60 "systemctl restart conntrackd" > /dev/null
  say "resync: restarted conntrackd on standby $standby, owner table $target"
  copy_wait "$standby" "$target"
  say "resync: standby copy $got of $target after about $(($(date +%s) - t0)) s"
  sleep 10
  samplers stop
  events "$1-resync" "$t0"
}

# takeover <label>: `natpair maintenance` on the owner, then samples both NATs until the new standby's copy holds 98%
# of the new owner's table, and resumes the old owner.
takeover() {
  local owner standby target t0 got i
  ready_wait 240
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  target=$(table_count "$owner")
  samplers sample "$t-$TAG-$1-takeover" 1200
  sleep 3
  t0=$(date +%s)
  on "$owner" 300 "natpair maintenance" > /dev/null &
  local maintenance=$!
  # natpair maintenance hands over only to a ready standby, so give up after about 3 minutes.
  for ((i = 0; i < 120; i++)); do
    [[ $(owner_nat) == "$standby" ]] && break
    sleep 1
  done
  if [[ $(owner_nat) != "$standby" ]]; then
    say "takeover: no handover after $(($(date +%s) - t0)) s, the standby never became ready"
    kill "$maintenance" 2> /dev/null
    on "$owner" 60 "pkill -f 'natpair maintenance'; natpair resume" > /dev/null
    samplers stop
    events "$1-takeover" "$t0"
    return 1
  fi
  say "takeover: shared ENI on $(owner_nat) after about $(($(date +%s) - t0)) s, old owner table $target"
  wait "$maintenance"
  copy_wait "$owner" "$target"
  say "takeover: new owner table $(table_count "$standby"), new standby copy $got after about $(($(date +%s) - t0)) s"
  sleep 10
  samplers stop
  events "$1-takeover" "$t0"
  on "$owner" 120 "natpair resume" > /dev/null
  ready_wait 240
}

sweep() {
  local size label
  for size in $SIZES; do
    label=$((size / 1024))k
    say "=== size $size"
    resize "$size"
    if ! fill_to $((size * 95 / 100)); then
      snap "$label-stopped"
      say "stopping the sweep at $size"
      return 1
    fi
    sleep 20
    snap "$label-full"
    tcp_run "$label"
    churn_run "$label" $((size / 800))
    resync "$label"
    snap "$label-after-resync"
    takeover "$label"
    snap "$label-after-takeover"
  done
}

# refill: clears every hold connection, then fills to 95% of REFILL_SIZE.
refill() {
  clear_all
  resize "$REFILL_SIZE"
  fill_to $((REFILL_SIZE * 95 / 100))
  sleep 20
  snap "refill$((REFILL_SIZE / 1024))k"
}

bufab() {
  local owner standby label=buf$((${BUFFER:-16777216} / 1048576))m
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  say "buffers: standby $(ctnat "$standby" 120 buffers "${BUFFER:-16777216}" | head -1)"
  say "buffers: owner $(ctnat "$owner" 120 buffers "${BUFFER:-16777216}" | head -1)"
  ready_wait 240
  # The owner's restart above came after the standby's, so the standby's startup copy may be cut short: this copy
  # is the measured one.
  resync "$label"
  snap "$label-after-resync"
  takeover "$label"
  snap "$label-after-takeover"
  for nat in "$standby" "$owner"; do
    on "$nat" 60 "sed -i -E '/^ *(Rcv|Snd)SocketBuffer /d' /var/lib/natpair/conntrackd.conf && systemctl restart conntrackd" > /dev/null
  done
  ready_wait 240
}

clear() {
  clear_all
  sleep 60
  snap cleared
}

# ready_after <nat> <epoch>: seconds from epoch until the NAT's first health round with "ready":true, or empty.
ready_after() {
  local at
  at=$(on "$1" 60 "journalctl -u natpair --since @$2 -o short-unix | grep '\"health round\"' | grep -m1 '\"ready\":true' | cut -d' ' -f1" | first_line)
  [[ -n $at ]] && awk -v a="$at" -v b="$2" 'BEGIN {printf "%.0f", a - b}'
}

# ready_by <nat> <epoch> <seconds>: waits up to that long for the NAT to log a ready round after epoch, and prints
# how long it took.
ready_by() {
  local i r
  for ((i = 0; i < $3; i += 10)); do
    r=$(ready_after "$1" "$2")
    if [[ -n $r ]]; then
      say "ready after $r s"
      return 0
    fi
    sleep 10
  done
  say "not ready after $3 s"
  return 1
}

# resync_fix <label>: resync, then how long the standby took to report ready.
resync_fix() {
  local owner standby t0
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  t0=$(date +%s)
  resync "$1"
  ready_by "$standby" "$t0" 600
}

# reboot_standby <label>: reboots the standby, as an upgrade does, then waits for its copy and for it to report
# ready.
reboot_standby() {
  local owner standby target t0 got i
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  target=$(table_count "$owner")
  samplers sample "$t-$TAG-$1-reboot" 1200
  t0=$(date +%s)
  on "$standby" 30 "nohup sh -c 'sleep 2; systemctl reboot' > /dev/null 2>&1 &" > /dev/null
  say "reboot: standby $standby rebooting, owner table $target"
  sleep 60
  for ((i = 0; i < 60; i++)); do
    [[ -n $(external_count "$standby") ]] && break
    sleep 5
  done
  say "reboot: standby back after about $(($(date +%s) - t0)) s"
  copy_wait "$standby" "$target"
  say "reboot: standby copy $got of $target after about $(($(date +%s) - t0)) s"
  ready_by "$standby" "$t0" 900
  samplers stop
  events "$1-reboot" "$t0"
}

# tcp_buckets <label> <size>: TCP with one bucket per entry, then a quarter, BUCKET_ROUNDS times, on both NATs.
tcp_buckets() {
  local r nat
  for ((r = 1; r <= ${BUCKET_ROUNDS:-2}; r++)); do
    for b in "$2" $(($2 / 4)); do
      for nat in "$NAT_A" "$NAT_B"; do ctnat "$nat" 120 buckets "$b" > /dev/null; done
      say "buckets $b: $(ctnat "$(owner_nat)" 60 buckets "$b" | head -1)"
      tcp_run "$1-b$b-r$r"
    done
  done
  for nat in "$NAT_A" "$NAT_B"; do ctnat "$nat" 120 buckets "$2" > /dev/null; done
}

# ports: PORTS_HELD connections to receiver port 7000 alone, from every generator address.
ports() {
  local held=${PORTS_HELD:-45000} per owner t0 ids=() n v k cmd mode
  per=$(((held + ${#addrs[@]} - 1) / ${#addrs[@]}))
  owner=$(owner_nat)
  start_server
  snap empty
  for mode in open close; do
    t0=$(date +%s)
    ids=()
    for n in "${!gens[@]}"; do
      v=GEN_ADDRS_$n
      read -r -a a <<< "${!v}"
      cmd="aws s3 cp --only-show-errors --region $AWS_REGION s3://$BUCKET/box/bin/hold /tmp/hold && chmod +x /tmp/hold
command -v iptables > /dev/null || dnf install -y -q iptables-nft > /dev/null 2>&1
iptables -t raw -C PREROUTING -p tcp -s $receiver_ip --sport 7000:7255 -j DROP 2> /dev/null || iptables -t raw -I PREROUTING -p tcp -s $receiver_ip --sport 7000:7255 -j DROP"
      for k in "${!a[@]}"; do
        cmd+="
/tmp/hold -target $receiver_ip -source ${a[k]} -ports 7000-7000 -from 0 -count $per -rate 2000 $([[ $mode == close ]] && echo -close) -out /tmp/hold-p$k.json &"
      done
      cmd+="
wait"
      ids+=("$(ssm_send "${gens[n]}" 600 "$cmd")")
    done
    for n in "${!gens[@]}"; do ssm_wait "${ids[n]}" "${gens[n]}" > /dev/null; done
    say "ports: $mode $((per * ${#addrs[@]})) connections to port 7000, owner table $(table_count "$owner")"
    sleep 75
    on "$owner" 60 "journalctl -u natpair --since @$t0 -o short-iso | grep -E 'shared address|back under' | cut -c1-600" | tee -a "$OUT/ports.txt"
    on "$owner" 60 "journalctl -u natpair --since @$t0 -o cat | grep '\"health round\"' | grep -o '\"shared_ports_used\":[0-9.e-]*' | sort | uniq -c" | tee -a "$OUT/ports.txt"
  done
}

fix() {
  local size=${FIX_SIZE:-524288} label nat
  label=$((size / 1024))k
  say "=== fix $size"
  if ((size != 524288)); then
    for nat in "$(other_nat "$(owner_nat)")" "$(owner_nat)"; do
      say "resizefix $size: $nat: $(ctnat "$nat" 300 resizefix "$size" | head -1)"
    done
    ready_wait 600
  fi
  fill_to $((size * 95 / 100)) || say "fill stopped early"
  sleep 20
  snap "fix$label-full"
  tcp_buckets "fix$label" "$size"
  resync_fix "fix$label"
  snap "fix$label-after-resync"
  reboot_standby "fix$label"
  snap "fix$label-after-reboot"
  takeover "fix$label"
  snap "fix$label-after-takeover"
}

receiver_firewall
for c in $CASES; do
  say "=== $c"
  "$c"
done
say "=== done"
