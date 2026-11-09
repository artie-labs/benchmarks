#!/bin/bash
# Queues a bench job on the Oracle bench box. The box runs jobs one at a time, oldest first, in /opt/oracle-bench with
# BUCKET set, after syncing box/ from S3. Output: s3://$BUCKET/results/queue/<timestamp>-<name>.log. History: s3://$BUCKET/results/queue/history.txt.
# Jobs: aws s3 ls s3://$BUCKET/images/queue/ (never deleted, the box tracks which ran).
# Usage: submit-job.sh <name> <script file> [queue]. queue is "queue" (the main box, with RDS) or "queue-replay" (the
# replay box, no database of its own). Default: queue.
set -euo pipefail
name=$1; file=$2; queue=${3:-queue}
BUCKET=benchmark-oracle-3debc8cdf0814272bcfd41b84c
key="images/$queue/$(date -u +%Y%m%dT%H%M%SZ)-$name.sh"
aws s3 cp --profile customer-sandbox --region us-west-2 "$file" "s3://$BUCKET/$key" --only-show-errors
echo "queued s3://$BUCKET/$key"
