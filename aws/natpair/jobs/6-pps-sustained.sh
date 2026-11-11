#!/bin/bash
# Phase 1, measurement 2: whether the packet-rate allowance has a burst too. UDP 64-byte payloads at UDP_CAP, under
# the CPU limit, for 10 minutes, sampled every 100 ms. A pps_allowance_exceeded rise partway in means a burst ran out.
. ./lib.sh
./run.sh "$NAT_INSTANCE_TYPE-pps-sustained" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=$UDP_CAP DURATION=600 POLL=100ms
