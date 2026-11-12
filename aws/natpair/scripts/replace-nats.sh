#!/bin/bash
# Replaces both NATs with -replace, as natpair's operations guide describes: the standby first, then a handover with
# `natpair maintenance`, then the old owner. New NATs boot the pinned release and the current instance type.
# Usage: replace-nats.sh [extra terraform args]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export AWS_PROFILE=${AWS_PROFILE:-$(sed -n 's/^aws_profile *= *"\(.*\)"/\1/p' "$here/tf/terraform.tfvars")}
export AWS_REGION=${AWS_REGION:-us-west-2}
tf() { terraform -chdir="$here/tf" "$@"; }
owner() {
  aws ec2 describe-network-interfaces --network-interface-ids "$(tf output -raw shared_eni_id)" \
    --query 'NetworkInterfaces[0].Attachment.InstanceId' --output text
}
wait_ready() {
  local id=$1 i out
  for ((i = 0; i < 60; i++)); do
    [[ $(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text) == Online ]] && break
    sleep 10
  done
  for ((i = 0; i < 60; i++)); do
    # Read the output whole: grep -q would stop reading early and fail the pipeline under pipefail.
    out=$("$here/scripts/onbox.sh" "$id" 30 'journalctl -u natpair -o cat | grep "\"health round\"" | tail -1' 2> /dev/null || true)
    [[ $out == *'"ready":true'* ]] && return 0
    sleep 15
  done
  echo "$id not ready" >&2
  return 1
}
key_of() { tf output -json nat_instance_ids | jq -r --arg id "$1" 'to_entries[] | select(.value == $id) | .key'; }

old_owner=$(owner)
owner_key=$(key_of "$old_owner")
standby_key=$([[ $owner_key == a ]] && echo b || echo a)
echo "owner $owner_key ($old_owner): replacing $standby_key first"
tf apply -input=false -auto-approve -no-color "$@" -replace="module.natpair.aws_instance.nat[\"$standby_key\"]" | grep -E '^Error|Apply complete'
wait_ready "$(tf output -json nat_instance_ids | jq -r ".$standby_key")"
"$here/scripts/onbox.sh" "$old_owner" 120 'natpair maintenance' > /dev/null
for ((i = 0; i < 60; i++)); do [[ $(owner) != "$old_owner" ]] && break; sleep 3; done
echo "owner now $(owner)"
tf apply -input=false -auto-approve -no-color "$@" -replace="module.natpair.aws_instance.nat[\"$owner_key\"]" | grep -E '^Error|Apply complete'
wait_ready "$(tf output -json nat_instance_ids | jq -r ".$owner_key")"
echo "both NATs replaced: $(tf output -json nat_instance_ids | jq -c .)"
