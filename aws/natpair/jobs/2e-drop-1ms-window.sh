#!/bin/bash
# Phase 1, measurement 1: the bandwidth counters at 1 ms while AWS drops. A long upload at BURST_CAP sampled every
# 10 ms. Once the receiver's rate falls below BASELINE_STOP (the burst is spent), a second enapoll samples the
# owner every 1 ms for 40 s, uploaded to s3://$BUCKET/runs/<run>-1ms/. The run itself stops 120 s after the fall.
. ./lib.sh
owner=$(owner_nat)
./run.sh "$NAT_INSTANCE_TYPE-drop-1ms-window" MODE=up PROCS=1 STREAMS=16 RATE=$BURST_CAP DURATION=3000 POLL=10ms \
  STOP_BELOW_GBPS=$BASELINE_STOP STOP_HOLD=120 &
run=$!
dev=$(ip -o route show default | awk '{print $5; exit}')
sleep 60
prev=$(cat /sys/class/net/$dev/statistics/rx_bytes)
while kill -0 $run 2> /dev/null; do
  sleep 5
  cur=$(cat /sys/class/net/$dev/statistics/rx_bytes)
  gbps=$(awk -v b=$((cur - prev)) 'BEGIN { printf "%.3f", b * 8 / 5 / 1e9 }')
  prev=$cur
  if awk -v g="$gbps" -v x="$BASELINE_STOP" 'BEGIN { exit !(g < x) }'; then
    echo "burst spent at $(date -u +%T), receiver at $gbps Gbps: sampling the owner every 1 ms"
    key=runs/$(date -u +%Y%m%dT%H%M%SZ)-$NAT_INSTANCE_TYPE-drop-1ms-sample
    on "$owner" 200 "aws s3 cp --only-show-errors s3://$BUCKET/box/bin/enapoll /tmp/enapoll1 && chmod +x /tmp/enapoll1 && /tmp/enapoll1 -i auto -interval 1ms -duration 40s -out /tmp/enapoll-1ms.csv && gzip -f /tmp/enapoll-1ms.csv && aws s3 cp --only-show-errors /tmp/enapoll-1ms.csv.gz s3://$BUCKET/$key/enapoll-1ms.csv.gz && echo uploaded $key"
    break
  fi
done
wait $run
