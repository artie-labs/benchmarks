#!/bin/bash
# Rebuilds results/<run>.json from the raw run files in S3 with the current box/analyze.py.
# Usage: reanalyze.sh [run name pattern], such as reanalyze.sh c7gn.medium-udp-ramp. Raw files stay in .runs/.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export AWS_PROFILE=${AWS_PROFILE:-$(sed -n 's/^aws_profile *= *"\(.*\)"/\1/p' "$here/tf/terraform.tfvars")}
bucket=$(terraform -chdir="$here/tf" output -raw bucket)
for run in $(aws s3 ls "s3://$bucket/runs/" | awk '{print $2}' | tr -d / | grep -e "${1:-.}"); do
  aws s3 sync --only-show-errors "s3://$bucket/runs/$run/" "$here/.runs/$run/"
  [[ -f $here/.runs/$run/meta.json ]] || continue
  python3 -I "$here/box/analyze.py" "$here/.runs/$run" > "$here/results/$run.json"
  python3 -I "$here/box/analyze.py" --brief "$here/results/$run.json"
done
