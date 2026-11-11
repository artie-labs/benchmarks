#!/bin/bash
# Phase 1, measurements 1 and 2 (packets per second): what one read of the allowance counters costs, how often they
# change under overload, and the forwarded packet rate where pps_allowance_exceeded starts to move.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
owner=$(owner_nat)
# Read cost on the idle owner: the ioctl enapoll uses, per interface, then `ethtool -S` as a process.
on "$owner" 300 "aws s3 cp --only-show-errors s3://$BUCKET/box/bin/enapoll /tmp/enapoll && chmod +x /tmp/enapoll
for i in \$(ls /sys/class/net | grep ^ens); do /tmp/enapoll -i \$i -bench 2000; done
s=\$(date +%s%N); for k in \$(seq 500); do ethtool -S ens5 > /dev/null; done
echo \"{\\\"ethtool_process_us\\\": \$(( (\$(date +%s%N) - s) / 500000 ))}\"" | tee "$RESULTS/readcost-$t-idle.txt"
# Packet rate ramp: UDP with 64-byte payloads over 16 flows. Each step offers 200k, 300k, 400k, 500k, 600k and 800k
# packets a second in total, then as many as the generators can send.
for rate in 6.4M 9.6M 12.8M 16M 19.2M 25.6M 0; do
  ./run.sh "$t-udp-ramp-$rate" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=$rate DURATION=30
done
# The counters under overload, sampled every 10 ms: steady, then 2 s on and 3 s off to time the edges.
for k in 1 2 3; do
  ./run.sh "$t-refresh-steady-$k" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=0 DURATION=60
  ./run.sh "$t-refresh-onoff-$k" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=0 DURATION=60 PATTERN=onoff ON=2 OFF=3
done
