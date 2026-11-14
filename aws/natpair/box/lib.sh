#!/bin/bash
# Helpers for jobs on the receiver: the bench layout and SSM Run Command on the NATs and generators.
. /etc/natpair-bench.env
. /opt/natpair-bench/bench.env
export AWS_REGION AWS_DEFAULT_REGION=$AWS_REGION BUCKET

# ssm_send <instance> <timeout seconds> <shell command>: starts the command as root and prints its command ID.
ssm_send() {
  local params
  params=$(python3 -I -c 'import json, sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": [sys.argv[2]]}))' "$3" "$2")
  aws ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript --timeout-seconds 60 \
    --parameters "$params" --query Command.CommandId --output text
}

# ssm_wait <command ID> <instance>: waits for the command, prints its output, and fails unless it succeeded.
ssm_wait() {
  local status
  while true; do
    sleep 3
    status=$(aws ssm get-command-invocation --command-id "$1" --instance-id "$2" --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Pending | InProgress | Delayed) continue ;; esac
    break
  done
  aws ssm get-command-invocation --command-id "$1" --instance-id "$2" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text
  [[ $status == Success ]]
}

# on <instance> <timeout seconds> <shell command>: runs a command and prints its output.
on() {
  local id
  id=$(ssm_send "$@") || return
  ssm_wait "$id" "$1"
}

owner_nat() {
  aws ec2 describe-network-interfaces --network-interface-ids "$SHARED_ENI" \
    --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text
}

shared_private_ip() {
  aws ec2 describe-network-interfaces --network-interface-ids "$SHARED_ENI" \
    --query 'NetworkInterfaces[0].PrivateIpAddress' --output text
}

other_nat() {
  if [[ $1 == "$NAT_A" ]]; then echo "$NAT_B"; else echo "$NAT_A"; fi
}

# host_command <role> <env assignments...>: the SSM command that runs host.sh on a NAT or generator.
host_command() {
  local role=$1
  shift
  echo "aws s3 cp --only-show-errors --region $AWS_REGION s3://$BUCKET/box/host.sh /tmp/natpair-bench-host.sh && env AWS_REGION=$AWS_REGION BUCKET=$BUCKET $* bash /tmp/natpair-bench-host.sh $role"
}

# wait_standby_ready: waits up to 10 minutes until the standby's latest health round says "ready":true.
wait_standby_ready() {
  local standby i
  for ((i = 0; i < 40; i++)); do
    standby=$(other_nat "$(owner_nat)")
    if on "$standby" 60 "journalctl -u natpair -o cat | grep '\"health round\"' | tail -1" | grep -q '"ready":true'; then
      echo "standby $standby ready"
      return 0
    fi
    sleep 15
  done
  echo "standby $standby not ready after 10 minutes"
  return 1
}

# Per NAT type: TCP_CAP is the iperf3 rate per flow that offers 4.5 Gbps (medium) or 10 Gbps (large) over 32 flows,
# above the baseline bandwidth but below what the NAT's CPU forwards, so AWS's allowance is the limit, not the CPU.
# UDP_CAP offers 450k (medium) or 900k (large) 64-byte packets a second over 16 flows, under the CPU limit.
# BURST_CAP offers 8 Gbps (medium) or 14 Gbps (large), about 80% of what the NAT's CPU forwards, to spend the burst
# allowance quickly. BASELINE_STOP is a little above the baseline bandwidth, where burst runs stop. UDP_HI offers
# 500k (medium) or 1M (large) 64-byte packets a second over 16 flows, just under what one CPU per vCPU forwards.
case $NAT_INSTANCE_TYPE in
  c7gn.medium) TCP_CAP=140M UDP_CAP=14.4M BURST_CAP=250M BASELINE_STOP=3.4 UDP_HI=16M ;;
  c7gn.large) TCP_CAP=312M UDP_CAP=28.8M BURST_CAP=437M BASELINE_STOP=6.6 UDP_HI=32M ;;
esac

# reset_pacing_caps restarts natpair on both NATs, so each starts from the configured caps again: the pacing build
# keeps its caps in memory and has no setting for the CPU cap. The standby restarts first, takes over through
# `natpair maintenance`, then the old owner restarts and resumes as the standby.
reset_pacing_caps() {
  local owner standby i
  owner=$(owner_nat)
  standby=$(other_nat "$owner")
  on "$standby" 60 "systemctl restart natpair" > /dev/null
  wait_standby_ready || return 1
  on "$owner" 120 "natpair maintenance" > /dev/null
  for ((i = 0; i < 60; i++)); do
    [[ $(owner_nat) == "$standby" ]] && break
    sleep 2
  done
  on "$owner" 60 "systemctl restart natpair && natpair resume" > /dev/null
  wait_standby_ready
  echo "pacing caps reset: owner now $(owner_nat)"
}

# guard_switch on|off: natpair's XDP overload guard on both NATs. off creates /var/lib/natpair/overload-guard-off,
# which detaches it within 5 s; on removes it, and the owner attaches it within 5 s.
guard_switch() {
  local nat cmd="rm -f /var/lib/natpair/overload-guard-off"
  [[ $1 == off ]] && cmd="touch /var/lib/natpair/overload-guard-off"
  for nat in "$NAT_A" "$NAT_B"; do
    on "$nat" 60 "$cmd" > /dev/null || echo "overload guard $1 failed on $nat"
  done
  sleep 7
}

# rx_switch on|off: natpair#13's control-plane priority on both NATs. off creates
# /var/lib/natpair/receive-threads-off, which turns threaded NAPI off within 5 s; on removes it.
rx_switch() {
  local nat cmd="rm -f /var/lib/natpair/receive-threads-off"
  [[ $1 == off ]] && cmd="touch /var/lib/natpair/receive-threads-off"
  for nat in "$NAT_A" "$NAT_B"; do
    on "$nat" 60 "$cmd" > /dev/null || echo "receive threads $1 failed on $nat"
  done
  sleep 7
}
