#!/bin/bash
# Runs from a systemd timer on the bench boxes every 10 minutes. When the root disk passes 75%, removes stopped
# containers, unused images and build cache, which is what filled the disk on 2026-11-08. Running containers,
# including Kafka during a job, are left alone.
used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if [ "${used:-0}" -ge 75 ]; then
  echo "$(date -u +%FT%TZ) disk ${used}%, pruning" >> /var/log/disk-guard.log
  docker container prune -f >/dev/null 2>&1
  docker image prune -af >/dev/null 2>&1
  docker builder prune -af >/dev/null 2>&1
  echo "$(date -u +%FT%TZ) disk now $(df --output=pcent / | tail -1 | tr -d ' ')" >> /var/log/disk-guard.log
fi
