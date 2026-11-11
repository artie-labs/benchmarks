#!/bin/bash
# Builds enapoll for the arm64 bench instances and NATs into box/bin, which terraform uploads.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p box/bin
(cd enapoll && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o ../box/bin/enapoll .)
