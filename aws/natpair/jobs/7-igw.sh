#!/bin/bash
# The one run through the internet gateway, the path production traffic takes: UDP 64-byte payloads at 450k packets
# a second for 60 s, sent to the receiver's public IP, so they leave the shared ENI through its Elastic IP. On the
# peering path this rate never moved pps_allowance_exceeded. Needs igw_check = true. About 5 GB of public transfer.
. ./lib.sh
./run.sh "$NAT_INSTANCE_TYPE-igw-udp" MODE=udp LEN=64 PROCS=1 STREAMS=8 RATE=14.4M DURATION=60 TARGET=public
