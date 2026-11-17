#!/bin/bash
# Queues jobs/regress.sh with jobs/ctsize.sh's helpers in front (everything before its section loop).
# Usage: submit-regress.sh <name> <BUILD> "<CASES>" [more KEY=value settings]. TF_DIR picks the stack.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
name=$1 build=$2 cases=$3
shift 3
job=$(mktemp)
{
  echo "BUILD=$build CASES='$cases' $*"
  echo "export BUILD CASES $(for kv in "$@"; do printf '%s ' "${kv%%=*}"; done)"
  sed -n '2,$p' "$here/jobs/ctsize.sh" | sed '/^receiver_firewall$/,$d' | sed 's/^CASES=\${CASES:-base}$/:/'
  sed -n '2,$p' "$here/jobs/regress.sh"
} > "$job"
bash -n "$job"
"$here/scripts/submit-job.sh" "$name" "$job"
rm -f "$job"
