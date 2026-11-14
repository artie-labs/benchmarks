#!/usr/bin/env python3
"""Summarizes a box/xdp.sh run: the longest ping reply gap around each attach, detach and MTU change, and for each
flood phase the received and XDP-dropped packet rates, CPU busy and nanoseconds of CPU per received packet.

Usage: xdp-summary.py <s3://<bucket>/runs/xdp/<label>/ copied locally>   (2 CPUs assumed, as on c7gn.large)
"""
import sys, os, re
d = sys.argv[1]
marks = [(float(l.split()[0]), " ".join(l.split()[1:4])) for l in open(f"{d}/log.txt") if re.match(r"^\d+\.\d+ (attach|detach|mtu|restored)", l)]
pings = []
for l in open(f"{d}/ping.txt"):
    m = re.match(r"^\[(\d+\.\d+)\].*icmp_seq=(\d+)", l)
    if m: pings.append((float(m.group(1)), int(m.group(2))))
print(f"ping replies {len(pings)}, last seq {pings[-1][1] if pings else 0}")
for t, what in marks:
    near = [p for p in pings if t - 2 < p[0] < t + 5]
    gaps = [(b[0] - a[0], a[0] - t) for a, b in zip(near, near[1:])]
    g = max(gaps) if gaps else (None, None)
    lost = (near[-1][1] - near[0][1] + 1 - len(near)) if near else None
    print(f"  {what:28s} longest reply gap {g[0] and round(g[0]*1000)} ms (starts {g[1] and round(g[1]*1000)} ms after), lost {lost} of {near and near[-1][1]-near[0][1]+1}")
def rdstat(p):
    for l in open(p):
        if l.startswith("cpu "): return [int(x) for x in l.split()[1:]]
def eth(p):
    out = {}
    for l in open(p):
        m = re.match(r"\s+([\w]+):\s+(\d+)", l)
        if m: out[m.group(1)] = int(m.group(2))
    return out
for ph in ("nox-1m", "nox-3m", "xdp-1m", "xdp-3m"):
    a, b = f"{d}/sample-{ph}-a", f"{d}/sample-{ph}-b"
    dt = float(open(f"{b}/time").read()) - float(open(f"{a}/time").read())
    s = [y - x for x, y in zip(rdstat(f"{a}/stat"), rdstat(f"{b}/stat"))]; tot = sum(s)
    busy = (tot - s[3] - s[4]) / tot  # fraction of all CPUs
    ea, eb = eth(f"{a}/ethtool"), eth(f"{b}/ethtool")
    dl = {k: (eb[k] - ea.get(k, 0)) / dt for k in eb}
    rx = sum(v for k, v in dl.items() if re.match(r"queue_\d+_rx_cnt$", k))
    xdrop = sum(v for k, v in dl.items() if re.match(r"queue_\d+_rx_xdp_drop$", k))
    pps_ex = dl.get("pps_allowance_exceeded", 0)
    rxp = (int(open(f"{b}/rx_packets").read()) - int(open(f"{a}/rx_packets").read())) / dt
    ncpu = 2
    ns = busy * ncpu * 1e9 / rx if rx else 0
    print(f"  {ph}: queue rx {rx/1e6:.3f}M pps, xdp_drop {xdrop/1e6:.3f}M pps, netdev rx_packets {rxp/1e6:.3f}M, pps_allowance_exceeded {pps_ex:.0f}/s, CPU busy {busy*100:.1f}% of 2 (softirq {s[6]/tot*100:.1f}%), {ns:.0f} ns per received packet; per-queue rx {[round(v) for k, v in sorted(dl.items()) if re.match(r'queue_\d+_rx_cnt$', k)]}")
