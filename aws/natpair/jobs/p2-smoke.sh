#!/bin/bash
# Phase 2 smoke: one short run of each mode, pacing off and on.
. ./lib.sh
t=$NAT_INSTANCE_TYPE
./run.sh "$t-p2-smoke-tcp-off" MODE=up PROCS=1 STREAMS=16 DURATION=20 PACING=off
./run.sh "$t-p2-smoke-tcp-on" MODE=up PROCS=1 STREAMS=16 DURATION=20 PACING=on
./run.sh "$t-p2-smoke-fair-on" MODE=fair LIGHT_RATE=100M DURATION=20 PACING=on
./run.sh "$t-p2-smoke-churn-on" MODE=churn CHURN_RATE=3000 DURATION=20 PACING=on
./run.sh "$t-p2-smoke-toggle" MODE=up PROCS=1 STREAMS=16 DURATION=60 TOGGLE_AT=15 PING=1 RPOLL=10ms PACING=on
