#!/bin/bash
# Runs a shell command on the Oracle bench box through SSM and prints its output.
# Usage: onbox.sh <instance-id> <timeout-seconds> <command...>
set -euo pipefail
instance=$1; timeout=$2; shift 2
cmd="$*"
params=$(python3 -I -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": [sys.argv[2]]}))' "cd /opt/oracle-bench 2>/dev/null || true; $cmd" "$timeout")
id=$(aws ssm send-command --profile customer-sandbox --region us-west-2 --instance-ids "$instance" \
  --document-name AWS-RunShellScript --parameters "$params" --query Command.CommandId --output text)
while true; do
  sleep 5
  status=$(aws ssm get-command-invocation --profile customer-sandbox --region us-west-2 --command-id "$id" \
    --instance-id "$instance" --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in Pending|InProgress|Delayed) continue ;; esac
  break
done
aws ssm get-command-invocation --profile customer-sandbox --region us-west-2 --command-id "$id" \
  --instance-id "$instance" --query '[StandardOutputContent,StandardErrorContent]' --output text
echo "[ssm status: $status]"
