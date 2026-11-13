#!/bin/bash
# Phase 2: a takeover with pacing on. TCP uploads at 2 Gbps, `natpair maintenance` on the owner 20 s in, then
# `natpair resume` after the run, 3 rounds with alternating owners. Afterwards each NAT's journal lines about pacing
# since the run started: which interface the new owner paces, and any "failed to read allowance counters".
# Output: $RESULTS/<type>-p2-takeover-<k>-pacing.txt.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
for k in 1 2 3; do
  wait_standby_ready || exit 1
  since=$(date +%s)
  ./run.sh "$t-p2-takeover-$k" MODE=up PROCS=1 STREAMS=16 RATE=62.5M DURATION=60 HANDOVER_AT=20 PING=1 PACING=on
  out="$RESULTS/$t-p2-takeover-$k-pacing.txt"
  : > "$out"
  for nat in "$NAT_A" "$NAT_B"; do
    {
      echo "== $nat since $since"
      on "$nat" 60 "journalctl -u natpair --since @$since -o short-iso-precise --no-pager | grep -iE 'pacing|allowance|ownership|forwarding open|interface' | head -60; echo \"counter read errors: \$(journalctl -u natpair --since @$since -o cat --no-pager | grep -c 'failed to read allowance counters')\"; ip -br link | grep -E '^(ens|eth)'"
    } >> "$out" 2>&1
  done
  cat "$out"
done
