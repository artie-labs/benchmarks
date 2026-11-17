#!/usr/bin/env python3
"""Splits each SIGKILL takeover in jobs/regress.sh's kill.txt into its steps: from the kill to the standby acquiring
the lease, then the takeover's steps to forwarding open, with the run's longest ping gap.

Usage: kill-split.py <regress results dir>  (holds kill.txt and runs.txt)
"""
import datetime, json, re, sys

d = sys.argv[1]
text = open(d + "/kill.txt", errors="replace").read()
gaps = re.findall(r"-kill-(\d+) \| ping loss [^ ]+ gap ([0-9.]+)s", open(d + "/runs.txt").read())
gaps = {int(k): float(g) for k, g in gaps}


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


rounds = re.split(r"^== kill (\d+):.*$", text, flags=re.M)
print("round  kill->acquired  acquired->open  kill->open  ping gap  steps (s)")
for i in range(1, len(rounds), 2):
    k, body = int(rounds[i]), rounds[i + 1]
    m = re.search(r"killed \d+ at (\d\d:\d\d:\d\d\.\d+)", body)
    if not m:
        continue
    day = re.search(r"(\d{4}-\d\d-\d\d)T", text).group(1)
    kill = ts(day + "T" + m.group(1) + "+00:00")
    acq = opened = None
    steps = []
    for line in body.splitlines():
        j = line[line.find("{"):] if "{" in line else ""
        try:
            e = json.loads(j)
        except ValueError:
            continue
        t = ts(e["time"])
        if t < kill:
            continue
        msg = e.get("msg")
        if msg == "ownership acquired" and acq is None and opened is None:
            acq = t
        elif msg == "forwarding open" and opened is None:
            opened = t
            # The acquired line may be cut short in the file. The takeover's own duration dates it.
            if acq is None and "takeover" in e:
                acq = t - e["takeover"] / 1e9
        elif msg == "handoff step" and acq and not opened:
            steps.append("%s %.1f" % (e["step"].replace(" ", "_"), e["duration"] / 1e9))
        elif msg == "shared ENI change sent" and acq and not opened:
            steps.append("eni_%s %.1f" % (e["change"], e["duration"] / 1e9))
        elif msg == "shared Elastic IP not working yet, trying again" and acq and not opened:
            steps.append("eip_retry")
    f = lambda x: "%.1f" % x if x is not None else "?"
    if acq and opened and steps:
        logged = sum(float(x.split()[-1]) for x in steps if x != "eip_retry")
        steps.append("unlogged (waiting for the attached ENI and the rest) %.1f" % (opened - acq - logged))
    print("%5d  %14s  %14s  %10s  %8s  %s" % (k, f(acq - kill if acq else None), f(opened - acq if acq and opened else None),
                                          f(opened - kill if opened else None), gaps.get(k, "?"), ", ".join(steps)))
