#!/bin/bash
# Runs a shell command as root on a bench instance or NAT through SSM and prints its output.
# Usage: onbox.sh <instance id> <timeout seconds> <command...>
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# The AWS profile comes from tf/terraform.tfvars unless AWS_PROFILE is set, so a command never falls through to the
# default profile's account.
export AWS_PROFILE=${AWS_PROFILE:-$(sed -n 's/^aws_profile *= *"\(.*\)"/\1/p' "$here/tf/terraform.tfvars")}
instance=$1; timeout=$2; shift 2
params=$(python3 -I -c 'import json, sys; print(json.dumps({"commands": [sys.argv[1]], "executionTimeout": [sys.argv[2]]}))' "$*" "$timeout")
id=$(aws ssm send-command --region "${AWS_REGION:-us-west-2}" --instance-ids "$instance" \
  --document-name AWS-RunShellScript --parameters "$params" --query Command.CommandId --output text)
while true; do
  sleep 3
  status=$(aws ssm get-command-invocation --region "${AWS_REGION:-us-west-2}" --command-id "$id" \
    --instance-id "$instance" --query Status --output text 2>/dev/null || echo Pending)
  case "$status" in Pending | InProgress | Delayed) continue ;; esac
  break
done
aws ssm get-command-invocation --region "${AWS_REGION:-us-west-2}" --command-id "$id" --instance-id "$instance" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text
echo "[ssm status: $status]"
