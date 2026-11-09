#!/bin/bash
# Transfer A/B on one partition: master 562f4334 vs parallel decode 8a4d77a2, each replaying the last Reader drain into S3.
set -euo pipefail
cd /opt/oracle-bench
BUCKET=benchmark-oracle-3debc8cdf0814272bcfd41b84c
oracle-bench-sync
aws s3 cp "s3://$BUCKET/images/steady.py" /root/steady.py --only-show-errors
for f in transfer-base-562f4334 transfer-decode-8a4d77a2; do aws s3 cp "s3://$BUCKET/images/$f.tar.gz" - | gunzip | docker load; done
# Where the replayed drain starts in the topic, for steady.py.
START=$(python3 -c "import json; print(json.load(open('state/engines.json'))['reader']['last_drain']['from'])")
A=oracle-bench/transfer:base-562f4334
B=oracle-bench/transfer:decode-8a4d77a2
rm -f results/transfer-steady.txt
for pair in 1 2 3 4 5; do
  if (( pair % 2 )); then order="$A $B"; else order="$B $A"; fi
  for image in $order; do
    tag=${image##*:}
    TRANSFER_IMAGE=$image ./bench.py --engine reader transfer-drain > "/tmp/tx-$pair-$tag.log" 2>&1
    docker compose logs --no-color --no-log-prefix transfer > "results/transfer-log-$pair-$tag.txt" 2>&1 || true
    echo "$pair $tag $(python3 /root/steady.py results/transfer-log-$pair-$tag.txt "$START" 2>&1 | tail -1)" >> results/transfer-steady.txt
  done
done
aws s3 sync results/ "s3://$BUCKET/results/" --only-show-errors
echo TX-DONE
