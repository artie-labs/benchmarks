#!/bin/bash
# Builds enapoll, churn and flood for the arm64 bench instances and NATs into box/bin, which terraform uploads.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p box/bin
for tool in enapoll churn flood; do
  (cd "$tool" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "../box/bin/$tool" .)
done
