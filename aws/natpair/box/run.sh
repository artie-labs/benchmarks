#!/bin/bash
# One measured run, from the receiver. Usage: run.sh <name> [KEY=value ...]
#
# Starts enapoll on both NATs, every generator and the receiver at the same moment, runs the iperf3 load from the
# generators, collects every host's files from S3 and writes the summary to $RESULTS/<run id>.json.
#
#   MODE=up|down|udp|udpdown|none  up: generators send to the receiver. down: the receiver sends (iperf3 -R).
#                          udp and udpdown: the same with UDP, only to find packet-rate limits. none: no load.
#   PROCS=2 STREAMS=8      iperf3 client processes per generator, and flows per process
#   RATE=                  iperf3 -b per flow, such as 50M. Empty: unlimited
#   MSS= LEN=              TCP --set-mss, and the UDP payload length
#   DURATION=60 PRE=5 POST=5  seconds of load, and of sampling before and after it
#   PATTERN=steady|onoff ON=2 OFF=2  onoff repeats ON seconds of load and OFF seconds idle
#   POLL=10ms              enapoll interval on the NATs. GPOLL and RPOLL (default 1s) set it on generators and receiver
#   PING=0|1               generator 0 pings the receiver 100 times a second through the NAT
#   HANDOVER_AT=           seconds into the load to run `natpair maintenance` on the owner, then `natpair resume`
#                          after the run
#   STOP_BELOW_GBPS=       end the run early once the receiver's rate (rx for up, tx for down) has been above this
#                          and then stays below it for STOP_HOLD=60 seconds. For burst runs: stop once throughput
#                          falls back to the baseline.
set -euo pipefail
cd /opt/natpair-bench
. ./lib.sh
RESULTS=${RESULTS:-/opt/natpair-bench-results}

name=$1
shift
MODE=up PROCS=2 STREAMS=8 RATE= MSS= LEN= DURATION=60 PRE=5 POST=5 PATTERN=steady ON=2 OFF=2
POLL=10ms GPOLL=1s RPOLL=1s PING=0 HANDOVER_AT= STOP_BELOW_GBPS= STOP_HOLD=60
for kv in "$@"; do
  case "${kv%%=*}" in
    MODE | PROCS | STREAMS | RATE | MSS | LEN | DURATION | PRE | POST | PATTERN | ON | OFF | POLL | GPOLL | RPOLL | PING | HANDOVER_AT | STOP_BELOW_GBPS | STOP_HOLD) declare "$kv" ;;
    *) echo "unknown setting: $kv" >&2; exit 2 ;;
  esac
done

run=$(date -u +%Y%m%dT%H%M%SZ)-$name
owner=$(owner_nat)
standby=$(other_nat "$owner")
receiver_ip=$(ip -4 -o route get 10.40.0.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
# SSM takes a few seconds to deliver a command, so everything starts on a shared clock a little later.
start=$(($(date +%s) + 20))
load_at=$((start + PRE))
sample=$((PRE + DURATION + POST))
common="RUN=$run START=$start LOAD_AT=$load_at SAMPLE_SECONDS=$sample PRE=$PRE DURATION=$DURATION MODE=$MODE PROCS=$PROCS STREAMS=$STREAMS RATE=$RATE MSS=$MSS LEN=$LEN PATTERN=$PATTERN ON=$ON OFF=$OFF RECEIVER_IP=$receiver_ip"
timeout=$((sample + 300))

systemctl restart 'iperf3@*'
sleep 1

echo "run $run: owner $owner, standby $standby, load at $(date -u -d "@$load_at" +%FT%TZ)"
declare -A commands
for nat in "$owner" "$standby"; do
  commands[$nat]=$(ssm_send "$nat" "$timeout" "$(host_command nat "$common INTERVAL=$POLL PING=0 GEN_INDEX=0")")
done
i=0
for gen in $GENERATORS; do
  ping=0
  [[ $i == 0 ]] && ping=$PING
  commands[$gen]=$(ssm_send "$gen" "$timeout" "$(host_command gen "$common INTERVAL=$GPOLL PING=$ping GEN_INDEX=$i")")
  i=$((i + 1))
done
env $common INTERVAL=$RPOLL PING=0 GEN_INDEX=0 BUCKET=$BUCKET AWS_REGION=$AWS_REGION \
  bash ./host.sh recv > "/tmp/natpair-bench-recv-$run.log" 2>&1 &
recv_pid=$!

stopped_at=
if [[ -n $STOP_BELOW_GBPS ]]; then
  stop_file=/tmp/natpair-bench-stop-$run
  (
    dev=$(ip -o route show default | awk '{print $5; exit}')
    counter=/sys/class/net/$dev/statistics/rx_bytes
    [[ $MODE == down || $MODE == udpdown ]] && counter=/sys/class/net/$dev/statistics/tx_bytes
    sleep "$((load_at + 10 - $(date +%s)))"
    seen_above=0 below_since=
    prev=$(cat "$counter") prev_t=$(date +%s.%N)
    while sleep 5; do
      cur=$(cat "$counter") cur_t=$(date +%s.%N)
      gbps=$(awk -v b="$((cur - prev))" -v t0="$prev_t" -v t1="$cur_t" 'BEGIN { printf "%.3f", b * 8 / (t1 - t0) / 1e9 }')
      prev=$cur prev_t=$cur_t
      if awk -v g="$gbps" -v x="$STOP_BELOW_GBPS" 'BEGIN { exit !(g > x) }'; then
        seen_above=1 below_since=
      elif [[ $seen_above == 1 ]]; then
        below_since=${below_since:-$(date +%s)}
        if (($(date +%s) - below_since >= STOP_HOLD)); then
          date +%s.%N > "$stop_file"
          echo "stopping: receiver at $gbps Gbps, below $STOP_BELOW_GBPS for ${STOP_HOLD}s"
          for instance in $GENERATORS "$owner" "$standby"; do
            ssm_send "$instance" 60 "pkill -TERM -x enapoll; pkill -TERM -x iperf3" > /dev/null
          done
          pkill -TERM -x enapoll
          break
        fi
      fi
    done
  ) &
  watcher=$!
fi

handover_sent= handover_done= resume_done=
if [[ -n $HANDOVER_AT ]]; then
  sleep "$(awk -v t="$((load_at + HANDOVER_AT))" -v n="$(date +%s.%N)" 'BEGIN { d = t - n; if (d < 0) d = 0; print d }')"
  handover_sent=$(date +%s.%N)
  on "$owner" 120 "natpair maintenance" || echo "natpair maintenance failed on $owner"
  handover_done=$(date +%s.%N)
fi

failed=0
for instance in "${!commands[@]}"; do
  ssm_wait "${commands[$instance]}" "$instance" || { echo "host.sh failed on $instance"; failed=1; }
done
wait "$recv_pid" || { echo "host.sh failed on the receiver"; failed=1; }
if [[ -n $STOP_BELOW_GBPS ]]; then
  kill "$watcher" 2> /dev/null || true
  [[ -f $stop_file ]] && stopped_at=$(cat "$stop_file")
fi

if [[ -n $HANDOVER_AT ]]; then
  on "$owner" 120 "natpair resume" || echo "natpair resume failed on $owner"
  resume_done=$(date +%s.%N)
fi

dir=/tmp/natpair-bench-runs/$run
mkdir -p "$dir"
python3 -I -c 'import json, sys; print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:]), indent=1))' \
  run="$run" name="$name" owner="$owner" standby="$standby" generators="$GENERATORS" receiver_ip="$receiver_ip" \
  shared_eni="$SHARED_ENI" shared_private_ip="$(shared_private_ip)" start="$start" load_at="$load_at" \
  nat_instance_type="$NAT_INSTANCE_TYPE" generator_instance_type="$GENERATOR_INSTANCE_TYPE" \
  receiver_instance_type="$RECEIVER_INSTANCE_TYPE" natpair_release="$NATPAIR_RELEASE" \
  handover_sent="$handover_sent" handover_done="$handover_done" resume_done="$resume_done" stopped_at="$stopped_at" \
  MODE="$MODE" PROCS="$PROCS" STREAMS="$STREAMS" RATE="$RATE" MSS="$MSS" LEN="$LEN" DURATION="$DURATION" PRE="$PRE" \
  POST="$POST" PATTERN="$PATTERN" ON="$ON" OFF="$OFF" POLL="$POLL" GPOLL="$GPOLL" RPOLL="$RPOLL" PING="$PING" \
  HANDOVER_AT="$HANDOVER_AT" STOP_BELOW_GBPS="$STOP_BELOW_GBPS" STOP_HOLD="$STOP_HOLD" > "$dir/meta.json"
aws s3 cp --only-show-errors "$dir/meta.json" "s3://$BUCKET/runs/$run/meta.json"
aws s3 sync --only-show-errors "s3://$BUCKET/runs/$run/" "$dir/"
mkdir -p "$RESULTS"
python3 -I ./analyze.py "$dir" > "$RESULTS/$run.json"
aws s3 cp --only-show-errors "$RESULTS/$run.json" "s3://$BUCKET/results/$run.json"
python3 -I ./analyze.py --brief "$RESULTS/$run.json"
exit $failed
