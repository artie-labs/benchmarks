#!/usr/bin/env python3
"""Steady Transfer rate from one run's log: messages committed by the last size-triggered flush, counted from the
drain's first message, over the time from partition assignment to that commit. Startup and the final time-triggered
flush's wait are left out. Usage: steady.py <transfer log, no compose prefix> <drain start offset, summed over partitions>"""
import datetime, json, re, sys
assigned, commits = None, []
for line in open(sys.argv[1]):
    stamp = line[:19]
    # docker compose logs keeps a restarted container's earlier runs, so only the last run counts.
    if "Partitions assigned" in line:
        assigned, commits = stamp, []
    if "Committed messages" in line:
        offsets = re.search(r'partitionToOffset="?map\[(.*?)\]', line).group(1)
        # A committed offset is the last applied message; the next to read is one past it.
        commits.append((stamp, sum(int(x.split(":")[1]) + 1 for x in offsets.split())))
def parse(s):
    return datetime.datetime.strptime("2026 " + s.strip(), "%Y %b %d %H:%M:%S.%f")
if assigned is None or not commits:
    sys.exit("no partition assignment or commits in the log")
start = int(sys.argv[2])
last_time, last_offset = commits[-2] if len(commits) > 1 else commits[-1]
seconds = (parse(last_time) - parse(assigned)).total_seconds()
messages = last_offset - start
print(json.dumps({"assigned_to_last_size_commit_s": round(seconds, 2), "messages": messages, "steady_msgs_per_s": round(messages / seconds) if seconds > 0 else None}))
