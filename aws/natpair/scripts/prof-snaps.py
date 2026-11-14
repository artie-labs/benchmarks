#!/usr/bin/env python3
"""Per-second deltas between the first two /proc snapshots of a box/prof.sh phase: the daemon's threads, ksoftirqd,
conntrackd and NAPI threads (run and runqueue wait from schedstat, utime and stime ticks), softirqs and CPU time.

Usage: prof-snaps.py <phase directory>
"""
import sys, os
def rd(d, f):
    try: return open(os.path.join(d, f)).read()
    except OSError: return ""
def procs(d, f):
    out = {}
    for line in rd(d, f).splitlines():
        p = line.split()
        if len(p) >= 7: out[p[0] + " " + p[1]] = [int(x) for x in p[2:7]]  # run_ns wait_ns slices utime stime
    return out
def softirqs(d):
    out = {}
    for line in rd(d, "softirqs").splitlines()[1:]:
        p = line.split(); out[p[0].rstrip(":")] = [int(x) for x in p[1:]]
    return out
def stat(d):
    for line in rd(d, "stat").splitlines():
        if line.startswith("cpu "): return [int(x) for x in line.split()[1:]]
base = sys.argv[1]
a, b = os.path.join(base, "snap-0"), os.path.join(base, "snap-1")
dt = float(rd(b, "time")) - float(rd(a, "time"))
print(f"{base}: {dt:.1f} s between snapshots 0 and 1 (perf record running)")
for f in ("tasks", "ksoftirqd", "conntrackd", "napi"):
    pa, pb = procs(a, f), procs(b, f)
    tot = [0] * 5
    for k in pb:
        if k in pa:
            dlt = [y - x for x, y in zip(pa[k], pb[k])]
            tot = [t + x for t, x in zip(tot, dlt)]
            if f != "tasks": print(f"  {k:20s} run {dlt[0]/1e9/dt*100:5.1f}% wait {dlt[1]/1e9/dt*100:5.1f}% slices/s {dlt[2]/dt:7.1f} utime+stime {(dlt[3]+dlt[4])/dt:5.1f} ticks/s")
    if f == "tasks" and pb: print(f"  natpair (all {len(pb)} threads) run {tot[0]/1e9/dt*100:5.1f}% runqueue wait {tot[1]/1e9/dt*100:5.1f}% slices/s {tot[2]/dt:7.1f} utime {tot[3]/dt:.1f} stime {tot[4]/dt:.1f} ticks/s")
sa, sb = softirqs(a), softirqs(b)
print("  softirqs/s:", ", ".join(f"{k} {[round((y-x)/dt) for x, y in zip(sa[k], sb[k])]}" for k in ("NET_RX", "NET_TX", "TIMER", "SCHED", "RCU") if k in sa))
ca, cb = stat(a), stat(b)
d = [y - x for x, y in zip(ca, cb)]; t = sum(d)
print("  cpu: " + " ".join(f"{n} {100*v/t:.1f}%" for n, v in zip(["user","nice","sys","idle","iowait","irq","softirq","steal"], d)))
print("  psi:", rd(b, "pressure_cpu").splitlines()[0] if rd(b, "pressure_cpu") else "-")
