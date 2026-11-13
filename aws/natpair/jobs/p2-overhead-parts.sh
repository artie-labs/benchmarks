#!/bin/bash
# Phase 2: which part of pacing costs the extra CPU per forwarded packet. TCP uploads at a fixed 4 Gbps and 8 Gbps
# (32 flows at 125 and 250 Mbit/s; 8 Gbps is the highest rate the unpaced medium forwards stable with CPU to spare),
# 45 s each, 3 rounds, on the owner's interfaces in four setups:
#   off   `natpair pacing-off`: the interfaces' default qdiscs, no BPF
#   fq    pacing off, plus the sch_fq root qdisc pacing installs (mq with one fq per queue on multi-queue ENIs)
#   bpf   fq plus pacing's own mark (ingress) and pace (egress) programs, attached with tc as natpair does, with a
#         limits value of no caps that never expires, so the programs do all their per-packet work but delay nothing
#   on    `natpair pacing-on`: full pacing
# For bpf, the job pins a second reference to the programs natpair loaded while pacing was on, so they survive
# `natpair pacing-off`, which removes natpair's own pins and stops writing limits. Nothing natpair runs touches the
# interfaces again while pacing stays off. The setups run on the owner only. The owner must not change during the job:
# a run with a takeover is reported, not repeated.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
owner=$(owner_nat)
standby=$(other_nat "$owner")
out="$RESULTS/$t-p2-overhead-parts.txt"
pins=/sys/fs/bpf/natpair-bench
both() { for nat in "$owner" "$standby"; do on "$nat" 60 "$1" > /dev/null || echo "'$1' failed on $nat"; done; }

# Removes whatever the job attached and leaves the owner's interfaces as `natpair pacing-off` does.
clear_manual='for i in ens5 ens6; do ip link show $i > /dev/null 2>&1 || continue
  tc qdisc del dev $i clsact 2> /dev/null; tc qdisc show dev $i | grep -q "qdisc .* 7a01: root" && tc qdisc del dev $i root; done; true'
# Installs pacing's qdiscs as natpair's attachScript does: fq limit 100000 flow_limit 10000, under mq handle 7a01:
# when the interface has more than one transmit queue.
install_fq='for i in ens5 ens6; do ip link show $i > /dev/null 2>&1 || continue
  q=$(ip -d -j link show dev $i | python3 -I -c "import json, sys; print(json.load(sys.stdin)[0][\"num_tx_queues\"])")
  if [ "$q" -gt 1 ]; then tc qdisc replace dev $i root handle 7a01: mq
    for n in $(seq 1 $q); do tc qdisc replace dev $i parent 7a01:$(printf %x $n) fq limit 100000 flow_limit 10000; done
  else tc qdisc replace dev $i root handle 7a01: fq limit 100000 flow_limit 10000; fi; done'
attach_bpf='for i in ens5 ens6; do ip link show $i > /dev/null 2>&1 || continue
  tc qdisc replace dev $i clsact
  tc filter replace dev $i ingress protocol all pref 7001 handle 1 bpf direct-action object-pinned '"$pins"'/mark
  tc filter replace dev $i egress protocol all pref 7001 handle 1 bpf direct-action object-pinned '"$pins"'/pace; done
  id=$(bpftool -j prog show pinned '"$pins"'/pace | python3 -I -c "import json, sys; print(\" \".join(str(m) for m in json.load(sys.stdin)[\"map_ids\"]))")
  for m in $id; do if bpftool -j map show id $m | grep -q natpair_limits; then
    exp=$(python3 -I -c "import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1e9) + 7200 * 10**9)")
    bpftool map update id $m key hex 00 00 00 00 value hex $(python3 -I -c "import sys; print(\" \".join(\"%02x\" % b for b in bytes(32) + int(sys.argv[1]).to_bytes(8, \"little\")))" $exp)
    echo "limits map $m: no caps until monotonic $exp"; fi; done'

{
  echo "owner $owner, standby $standby"
  both "natpair pacing-on"
  sleep 5
  on "$owner" 60 "rm -rf $pins; mkdir -p $pins && bpftool prog pin pinned /sys/fs/bpf/natpair/pacing/mark $pins/mark && bpftool prog pin pinned /sys/fs/bpf/natpair/pacing/pace $pins/pace && ls $pins"
  for k in 1 2 3; do
    for rate in 125M 250M; do
      for setup in off fq bpf on; do
        case $setup in
          off) both "natpair pacing-off"; on "$owner" 60 "$clear_manual" > /dev/null ;;
          fq) both "natpair pacing-off"; on "$owner" 60 "$clear_manual; $install_fq" > /dev/null ;;
          bpf) both "natpair pacing-off"; on "$owner" 60 "$clear_manual; $install_fq; $attach_bpf" ;;
          on) on "$owner" 60 "$clear_manual" > /dev/null; both "natpair pacing-on" ;;
        esac
        sleep 3
        echo "== $setup $rate round $k: $(on "$owner" 30 'for i in ens5 ens6; do echo "$i: $(tc qdisc show dev $i | cut -d" " -f2-3 | sort -u | tr "\n" " ")| $(tc filter show dev $i ingress 2> /dev/null | grep -o "bpf.*" | head -1) $(tc filter show dev $i egress 2> /dev/null | grep -o "bpf.*" | head -1)"; done' | tr '\n' ' ')"
        ./run.sh "$t-p2-parts-$setup-$rate-$k" MODE=up PROCS=1 STREAMS=16 RATE=$rate DURATION=45 POLL=1s PACING=keep
        [[ $(owner_nat) == "$owner" ]] || echo "owner changed during $setup $rate round $k"
      done
    done
  done
  # Pacing off first, so natpair removes its own attachments and attaches afresh on pacing-on. Clearing the
  # interfaces while pacing is on would leave natpair believing it still paces them.
  both "natpair pacing-off"
  on "$owner" 60 "$clear_manual; rm -rf $pins" > /dev/null
  both "natpair pacing-on"
} 2>&1 | tee -a "$out"
