#!/bin/bash
# Queues a job on the receiver. Usage: submit-job.sh <name> <script file>
# The receiver runs jobs one at a time, oldest first. Output: s3://<bucket>/results/queue/<timestamp>-<name>.log.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# TF_DIR picks another stack's Terraform directory, such as tf-m for a second stack beside tf.
tfdir=${TF_DIR:-$here/tf}
# The AWS profile comes from tf/terraform.tfvars unless AWS_PROFILE is set, so a command never falls through to the
# default profile's account.
export AWS_PROFILE=${AWS_PROFILE:-$(sed -n 's/^aws_profile *= *"\(.*\)"/\1/p' "$tfdir/terraform.tfvars")}
bucket=$(terraform -chdir="$tfdir" output -raw bucket)
key="jobs/$(date -u +%Y%m%dT%H%M%SZ)-$1.sh"
aws s3 cp --only-show-errors --region "${AWS_REGION:-us-west-2}" "$2" "s3://$bucket/$key"
echo "queued s3://$bucket/$key"
