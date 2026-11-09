#!/bin/bash
# Runs the direct redo reader's RDS 19c validation kit once the Transfer A/B is done, so the two don't share the box's CPU.
set -uo pipefail
BUCKET=benchmark-oracle-3debc8cdf0814272bcfd41b84c
while systemctl is-active --quiet ab-transfer2; do sleep 30; done
mkdir -p /root/redo && cd /root/redo
aws s3 cp "s3://$BUCKET/images/redo-kit.tgz" - --only-show-errors | tar -xz
ENV=/opt/oracle-bench/.env
export ORACLE_HOST=$(grep '^ORACLE_HOST=' $ENV | cut -d= -f2)
SECRET=$(grep '^MASTER_SECRET_ARN=' $ENV | cut -d= -f2)
REGION=$(grep '^AWS_REGION=' $ENV | cut -d= -f2)
export ORACLE_PASSWORD=$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SECRET" --query SecretString --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
export OUT=/root/redo/results
cd /root/redo/oracle-redo-rds && ./run.sh
echo "run.sh exit $?"
aws s3 sync /root/redo/results "s3://$BUCKET/results/redo/" --only-show-errors
echo REDO-DONE
