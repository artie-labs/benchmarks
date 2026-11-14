#!/bin/bash
# Builds enapoll, churn and flood for the arm64 bench instances and NATs into box/bin, which terraform uploads, and
# the XDP test programs in xdp/ when clang (CLANG, default clang) has the BPF target.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p box/bin
for tool in enapoll churn flood; do
  (cd "$tool" && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "../box/bin/$tool" .)
done
clang=${CLANG:-clang}
if "$clang" -print-targets 2> /dev/null | grep -qw bpf; then
  for prog in pass drop; do
    "$clang" -O2 -g -target bpf -c "xdp/$prog.c" -o "box/bin/xdp_$prog.o"
  done
else
  echo "skipping xdp/: $clang has no BPF target (set CLANG, such as Homebrew's llvm clang)" >&2
fi
