#!/bin/bash
# Phase 1, measurements 1 and 2 (packets per second): what one read of the allowance counters costs on the idle
# owner, the forwarded packet rate the NAT reaches before its CPU or an allowance gives out, and what the pair does
# when offered more than its CPU forwards. linklocal.sh measures the counters' refresh precisely.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
owner=$(owner_nat)
# Read cost on the idle owner: the ioctl enapoll uses, per interface, then `ethtool -S` as a process.
on "$owner" 300 "aws s3 cp --only-show-errors s3://$BUCKET/box/bin/enapoll /tmp/enapoll && chmod +x /tmp/enapoll
for i in \$(ls /sys/class/net | grep ^ens); do /tmp/enapoll -i \$i -bench 2000; done
s=\$(date +%s%N); for k in \$(seq 500); do ethtool -S ens5 > /dev/null; done
echo \"{\\\"ethtool_process_us\\\": \$(( (\$(date +%s%N) - s) / 500000 ))}\"" | tee "$RESULTS/readcost-$t-idle.txt"
# Packet rate ramp: UDP with 64-byte payloads over 16 flows, offering 200k, 400k, 600k, 800k, 1M and 1.2M packets a
# second in total, then as many as the generators can send.
for rate in 6.4M 12.8M 19.2M 25.6M 32M 38.4M 0; do
  ./run.sh "$t-udp-ramp-$rate" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=$rate DURATION=30
done
# Offered more than the CPU forwards, 3 times.
for k in 1 2 3; do
  ./run.sh "$t-overload-$k" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=0 DURATION=60
done
