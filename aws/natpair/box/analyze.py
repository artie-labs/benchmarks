#!/usr/bin/env python3
"""Summarizes one run directory (meta.json plus one folder per instance) as JSON on stdout.

Usage: analyze.py <run dir>         full summary
       analyze.py --brief <summary>  one line from a summary file

Python 3.9, standard library only, so it runs on Amazon Linux 2023 as is.
"""
import csv
import glob
import gzip
import json
import os
import re
import statistics
import sys

COUNTERS = [
    "bw_in_allowance_exceeded",
    "bw_out_allowance_exceeded",
    "pps_allowance_exceeded",
    "conntrack_allowance_exceeded",
    "linklocal_allowance_exceeded",
]
# Seconds left out at each end of the load, so iperf3 startup and teardown don't count toward steady rates.
SETTLE = 3
JOURNAL_PATTERNS = {
    "lease_store_unreachable": r"lease store unreachable",
    "conntrackd_not_answering": r"conntrackd is not answering",
    "copied_connections_incomplete": r"copied connections are incomplete",
    "forwarding_open": r"forwarding open",
    "ownership_acquired": r"ownership acquired",
    "stepped_down": r"ownership session ended",
    "dns_or_probe_timeout": r"failed to resolve probe receiver|shared Elastic IP not working yet",
    "conntrackd_resync": r"conntrackd.*resync",
    "conntrackd_netlink_loss": r"(?i)conntrackd.*(netlink|overrun|ENOBUFS|no buffer space|lost)",
    "pacing_cut_allowance": r"pacing cut its cap",
    "pacing_cut_cpu": r"forwarding CPU is nearly full",
    "pacing_stopped_cutting": r"stopped cutting it",
    "probe_errors": r'"probe_error":"',
    "conntrack_full": r"connection table is full",
    "pacing_failed": r"failed to load pacing|failed to pace",
    "pacing_off": r"pacing off|pacing-off|pacing turned off|pacing is off",
    "conntrack_nearly_full": r"connection table is nearly full",
    "counter_read_errors": r"failed to read allowance counters",
    "kernel_table_full": r"nf_conntrack: table full",
    # natpair#15: a timed-out probe followed by handshakes that partly completed (congested, not counted), and
    # health rounds that report it. path_check_failed: the handshakes couldn't be tried, so the round counted.
    "path_alive": r"the health probe failed, but the path is alive",
    "congested_rounds": r'"congested":true',
    "path_check_failed": r"failed to check whether the path is alive",
    # natpair's XDP overload guard on the shared ENI.
    "guard_attached": r"overload guard attached",
    "guard_detached": r"overload guard detached",
    "guard_engaged": r"overload guard engaged",
    "guard_cleared": r"overload guard cleared",
    "guard_failed": r"overload guard failed",
}


def summarize(stats):
    if not stats:
        return None
    s = sorted(stats)
    return {
        "n": len(s),
        "min": round(s[0], 3),
        "p10": round(s[int(0.1 * (len(s) - 1))], 3),
        "median": round(statistics.median(s), 3),
        "p90": round(s[int(0.9 * (len(s) - 1))], 3),
        "max": round(s[-1], 3),
    }


def read_enapoll(path):
    """Returns {iface: list of rows}, each row a dict of ints, time in seconds as t."""
    by_iface = {}
    with gzip.open(path, "rt") as f:
        for row in csv.DictReader(f):
            # A sampler stopped mid-write leaves a short last row.
            if row.get("linklocal_allowance_exceeded") is None:
                continue
            r = {"t": int(row["t_ns"]) / 1e9, "read_ns": int(row["read_ns"])}
            for k in ("rx_packets", "tx_packets", "rx_bytes", "tx_bytes"):
                r[k] = int(row[k])
            for k in COUNTERS:
                r[k] = int(row[k]) if row[k] else None
            by_iface.setdefault(row["iface"], []).append(r)
    return by_iface


def read_interfaces(host_dir):
    names = {}
    for name in ("interfaces-start.txt", "interfaces-end.txt"):
        path = os.path.join(host_dir, name)
        if os.path.exists(path):
            for line in open(path):
                parts = line.split()
                if len(parts) >= 2:
                    names[parts[0]] = {"eni": parts[1], "ips": parts[2] if len(parts) > 2 else ""}
    return names


def window(rows, start, end):
    return [r for r in rows if start <= r["t"] <= end]


def rates(rows, start, end):
    """Average packet and bit rates between the first and last sample inside [start, end]."""
    w = window(rows, start, end)
    if len(w) < 2:
        return None
    dt = w[-1]["t"] - w[0]["t"]
    out = {"seconds": round(dt, 2)}
    for k in ("rx", "tx"):
        out[k + "_pps"] = round(increase(w, k + "_packets") / dt)
        out[k + "_gbps"] = round(increase(w, k + "_bytes") * 8 / dt / 1e9, 3)
    for c in COUNTERS:
        if w[0][c] is not None:
            out[c] = increase(w, c)
            out[c + "_per_s"] = round(out[c] / dt)
    # Sampling gaps of over three intervals mean the interface was gone, such as the shared ENI during a takeover,
    # or the sampler was starved of CPU.
    gaps = [b["t"] - a["t"] for a, b in zip(w, w[1:])]
    usual = statistics.median(gaps)
    out["missing_s"] = round(sum(g for g in gaps if g > max(3 * usual, 0.05)), 2)
    return out


def increase(rows, key):
    """Sum of the counter's increases. A counter that restarts from zero, when an interface comes back, adds no drop."""
    total = 0
    for a, b in zip(rows, rows[1:]):
        if a[key] is not None and b[key] is not None and b[key] >= a[key]:
            total += b[key] - a[key]
    return total


def per_second(rows, t0):
    """Rates and counter increases per whole second, relative to t0."""
    buckets = {}
    for r in rows:
        buckets.setdefault(int(r["t"] - t0 + 1000) - 1000, r)
    keys = sorted(buckets)
    out = []
    for a, b in zip(keys, keys[1:]):
        ra, rb = buckets[a], buckets[b]
        dt = rb["t"] - ra["t"]
        if dt <= 0:
            continue
        if any(rb[k] < ra[k] for k in ("rx_packets", "tx_packets")):
            continue
        item = {
            "t": a,
            "rx_pps": round((rb["rx_packets"] - ra["rx_packets"]) / dt),
            "tx_pps": round((rb["tx_packets"] - ra["tx_packets"]) / dt),
            "rx_gbps": round((rb["rx_bytes"] - ra["rx_bytes"]) * 8 / dt / 1e9, 3),
            "tx_gbps": round((rb["tx_bytes"] - ra["tx_bytes"]) * 8 / dt / 1e9, 3),
        }
        for c in COUNTERS:
            if ra[c] is not None and rb[c] is not None and rb[c] > ra[c]:
                item[c] = rb[c] - ra[c]
        out.append(item)
    return out


def counter_changes(rows, start, end):
    """For each counter: the times (s) it changed between start and end, and the gaps between changes in ms."""
    out = {}
    for c in COUNTERS:
        times = []
        prev = None
        for r in rows:
            v = r[c]
            if v is None:
                continue
            if prev is not None and v != prev and start <= r["t"] <= end:
                times.append(r["t"])
            prev = v
        if not times:
            continue
        gaps = [(b - a) * 1000 for a, b in zip(times, times[1:])]
        sample_gaps = [(b["t"] - a["t"]) * 1000 for a, b in zip(rows, rows[1:]) if start <= a["t"] <= end]
        out[c] = {
            "changes": len(times),
            "first_change_s": round(times[0] - start, 3),
            "gap_ms": summarize(gaps),
            "sample_gap_ms": summarize(sample_gaps),
            "times": [round(t - start, 4) for t in times[:300]],
        }
    return out


def load_edges(rows, interval_s=0.05):
    """Finds when load started and stopped from the received packet rate, in 50 ms steps."""
    if len(rows) < 3:
        return []
    series = []
    i = 0
    for j in range(1, len(rows)):
        if rows[j]["t"] - rows[i]["t"] >= interval_s:
            series.append((rows[j]["t"], (rows[j]["rx_packets"] - rows[i]["rx_packets"]) / (rows[j]["t"] - rows[i]["t"])))
            i = j
    if not series:
        return []
    peak = sorted(v for _, v in series)[int(0.9 * (len(series) - 1))]
    threshold = 0.3 * peak
    edges = []
    on = series[0][1] > threshold
    for t, v in series:
        if (v > threshold) != on:
            on = not on
            edges.append(("on" if on else "off", t))
    return edges


def edge_delays(rows, edges):
    """Delay from each load start to the counter's first change, and from each stop to its last change."""
    out = {}
    for c in COUNTERS:
        times = []
        prev = None
        for r in rows:
            if r[c] is None:
                continue
            if prev is not None and r[c] != prev:
                times.append(r["t"])
            prev = r[c]
        if not times:
            continue
        on_delays, off_delays = [], []
        for k, (kind, t) in enumerate(edges):
            nxt = edges[k + 1][1] if k + 1 < len(edges) else float("inf")
            later = [x for x in times if t <= x < nxt]
            if kind == "on" and later:
                on_delays.append((later[0] - t) * 1000)
            if kind == "off":
                off_delays.append((later[-1] - t) * 1000 if later else 0.0)
        out[c] = {"first_change_after_load_start_ms": summarize(on_delays), "last_change_after_load_stop_ms": summarize(off_delays)}
    return out


def cpu_usage(host_dir, start, end):
    """Per-CPU percentages and process CPU (percent of one CPU) between the first and last sample in the window."""
    path = os.path.join(host_dir, "cpu.csv")
    if not os.path.exists(path):
        return None
    rows = {}
    for row in csv.DictReader(open(path)):
        t = int(row["t_ns"]) / 1e9
        if start <= t <= end:
            rows.setdefault(row["name"], []).append((t, row))
    out = {"cpus": {}, "procs": {}}
    busy_cores = 0.0
    soft_cores = 0.0
    for name, samples in rows.items():
        if len(samples) < 2:
            continue
        (t0, a), (t1, b) = samples[0], samples[-1]
        if name.startswith("proc:"):
            jiffies = (int(b["user"]) + int(b["system"])) - (int(a["user"]) + int(a["system"]))
            out["procs"][name[5:]] = {
                "cpu_pct": round(jiffies / (t1 - t0), 1),
                "user_pct": round((int(b["user"]) - int(a["user"])) / (t1 - t0), 1),
                "system_pct": round((int(b["system"]) - int(a["system"])) / (t1 - t0), 1),
            }
            continue
        keys = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"]
        d = {k: int(b[k]) - int(a[k]) for k in keys}
        total = sum(d.values()) or 1
        pct = {k: round(100.0 * v / total, 1) for k, v in d.items()}
        out["cpus"][name] = pct
        if name != "cpu":
            busy_cores += 1 - (d["idle"] + d["iowait"]) / total
            soft_cores += d["softirq"] / total
    out["busy_cores"] = round(busy_cores, 3)
    out["softirq_cores"] = round(soft_cores, 3)
    return out


def iperf_summary(host_dir):
    files = sorted(glob.glob(os.path.join(host_dir, "iperf-*.json")))
    if not files:
        return None
    out = {"files": len(files), "errors": [], "sent_gbps": 0.0, "received_gbps": 0.0, "retransmits": 0}
    steady = [f for f in files if "-steady-" in f]
    for path in files:
        try:
            data = json.load(open(path))
        except ValueError:
            out["errors"].append(os.path.basename(path) + ": not JSON")
            continue
        if data.get("error"):
            out["errors"].append(os.path.basename(path) + ": " + data["error"])
        end = data.get("end", {})
        if path not in steady:
            continue
        if "sum_sent" in end:
            out["sent_gbps"] += end["sum_sent"]["bits_per_second"] / 1e9
            out["received_gbps"] += end["sum_received"]["bits_per_second"] / 1e9
            out["retransmits"] += end["sum_sent"].get("retransmits", 0)
        elif "sum" in end:
            s = end["sum"]
            out["sent_gbps"] += s.get("bits_per_second", 0) / 1e9
            out.setdefault("udp_packets", 0)
            out.setdefault("udp_lost_packets", 0)
            out["udp_packets"] += s.get("packets", 0)
            out["udp_lost_packets"] += s.get("lost_packets", 0)
    out["sent_gbps"] = round(out["sent_gbps"], 3)
    out["received_gbps"] = round(out["received_gbps"], 3)
    return out


def ping_summary(host_dir, load_at, handover_at):
    path = os.path.join(host_dir, "ping.txt")
    if not os.path.exists(path):
        return None
    replies = []
    sent = set()
    for line in open(path):
        m = re.match(r"\[(\d+\.\d+)\] .*icmp_seq=(\d+)", line)
        if not m:
            continue
        sent.add(int(m.group(2)))
        if "bytes from" in line:
            replies.append(float(m.group(1)))
    if not replies:
        return {"sent": len(sent), "received": 0}
    gaps = [(b - a, a) for a, b in zip(replies, replies[1:])]
    gap, gap_start = max(gaps) if gaps else (0, replies[0])
    out = {
        "sent": len(sent),
        "received": len(replies),
        "loss_pct": round(100.0 * (1 - len(replies) / max(len(sent), 1)), 2),
        "longest_gap_s": round(gap, 3),
        "longest_gap_starts_s_after_load": round(gap_start - load_at, 3),
    }
    if handover_at:
        out["longest_gap_starts_s_after_handover"] = round(gap_start - handover_at, 3)
    return out


def receive_gap(rows, start, end):
    """Longest stretch inside [start, end] when the receiver got under 5% of its median packet rate."""
    w = window(rows, start, end)
    if len(w) < 3:
        return None
    steps = [((b["rx_packets"] - a["rx_packets"]) / (b["t"] - a["t"]), a["t"], b["t"]) for a, b in zip(w, w[1:]) if b["t"] > a["t"]]
    median = statistics.median(s[0] for s in steps)
    longest, cur_start, best_start = 0.0, None, None
    for rate, t0, t1 in steps:
        if rate < 0.05 * median:
            cur_start = t0 if cur_start is None else cur_start
            if t1 - cur_start > longest:
                longest, best_start = t1 - cur_start, cur_start
        else:
            cur_start = None
    return {"median_rx_pps": round(median), "longest_gap_s": round(longest, 3), "gap_start": best_start}


def journal_summary(host_dir):
    path = os.path.join(host_dir, "journal.txt")
    if not os.path.exists(path):
        return None
    counts = {k: 0 for k in JOURNAL_PATTERNS}
    examples = {}
    for line in open(path, errors="replace"):
        for k, pattern in JOURNAL_PATTERNS.items():
            if re.search(pattern, line):
                counts[k] += 1
                examples.setdefault(k, []).append(line.strip()[:300])
    return {"counts": counts, "examples": {k: v[:3] for k, v in examples.items()}}


def pacing_status(host_dir):
    """The last `pacing status` line natpair logged in the run, as a dict."""
    path = os.path.join(host_dir, "journal.txt")
    if not os.path.exists(path):
        return None
    last = None
    count = 0
    cuts = 0
    for line in open(path, errors="replace"):
        if '"pacing status"' in line:
            try:
                last = json.loads(line[line.index("{"):])
                count += 1
                cuts += last.get("cap_cuts", 0)
            except ValueError:
                pass
    if last is None:
        return None
    last = {k: v for k, v in last.items() if k not in ("time", "level", "msg")}
    last["lines"] = count
    last["cap_cuts_total"] = cuts
    return last


def bpf_stats(host_dir):
    """Run time per invocation of each BPF program that ran during the run, from bpftool before and after."""
    a, b = os.path.join(host_dir, "bpf-start.json"), os.path.join(host_dir, "bpf-end.json")
    if not (os.path.exists(a) and os.path.exists(b)):
        return None
    try:
        before = {p["id"]: p for p in json.load(open(a))}
        after = json.load(open(b))
    except ValueError:
        return None
    out = {}
    for p in after:
        old = before.get(p["id"], {})
        runs = p.get("run_cnt", 0) - old.get("run_cnt", 0)
        if runs <= 0:
            continue
        ns = p.get("run_time_ns", 0) - old.get("run_time_ns", 0)
        out["%s:%s" % (p.get("type"), p.get("name", p["id"]))] = {"runs": runs, "ns_per_run": round(ns / runs, 1)}
    return out


def conntrack_stats(host_dir, start, end):
    path = os.path.join(host_dir, "conntrack.csv")
    if not os.path.exists(path):
        return None
    rows = [r for r in csv.DictReader(open(path)) if r.get("search_restart") not in (None, "")]
    rows = [r for r in rows if start <= float(r["t"]) <= end] or rows
    if not rows:
        return None
    out = {"max_count": max(int(r["count"]) for r in rows), "median_count": int(statistics.median(int(r["count"]) for r in rows))}
    for k in ("drop", "early_drop", "insert_failed", "error"):
        out[k] = int(rows[-1][k]) - int(rows[0][k])
    full = os.path.join(host_dir, "conntrack-table-full.txt")
    if os.path.exists(full):
        out["dmesg_table_full_lines"] = int(open(full).read().strip() or 0)
    return out


def pacing_limits(host_dir, load_at):
    """Pacing's caps once a second from limits.txt: seconds since the load started, the aggregate packet cap in kpps
    and the aggregate byte cap in Mbit/s. None means no cap."""
    path = os.path.join(host_dir, "limits.txt")
    if not os.path.exists(path):
        return None
    series = []
    for line in open(path):
        parts = line.split(None, 1)
        try:
            raw = bytes(int(b, 16) for b in json.loads(parts[1])[0]["value"])
        except (IndexError, KeyError, ValueError):
            continue
        if len(raw) < 40:
            continue
        costs = [int.from_bytes(raw[i * 8:(i + 1) * 8], "little") for i in range(5)]
        kpps = round(1e9 / costs[1] / 1e3, 1) if costs[1] else None
        mbps = round(1e9 * 65536 / costs[0] * 8 / 1e6, 1) if costs[0] else None
        series.append([round(float(parts[0]) - load_at, 1), kpps, mbps])
    if not series:
        return None
    capped = [s[1] for s in series if s[1] is not None]
    return {
        "series": series,
        "kpps_min": min(capped) if capped else None,
        "kpps_median": statistics.median(capped) if capped else None,
        "uncapped_samples": sum(1 for s in series if s[1] is None),
    }


def threaded(host_dir):
    """natpair#13's state at the start of the run: threaded NAPI per interface (1 or 0) and the nice values of the
    receive threads, from threaded.txt."""
    path = os.path.join(host_dir, "threaded.txt")
    if not os.path.exists(path):
        return None
    out = {"threaded": {}, "napi_nice": {}}
    for line in open(path):
        if line.startswith("/sys/class/net/"):
            name, _, value = line.strip().partition(":")
            out["threaded"][name.split("/")[4]] = value
        elif "napi/" in line:
            nice, comm = line.split(None, 1)
            out["napi_nice"][comm.strip()] = nice
    return out


def nic_drops(host_dir):
    """Per ENI over the sampling: packets received, rx_dropped (the NIC's drops plus XDP drops on ENA), the dropped
    share (rx_dropped here includes rx_over_errors), and the XDP program id at the start and end (natpair's overload guard), from nic-start.txt and nic-end.txt.
    Also the guard's off switch, from guard.txt."""
    def read(name):
        path = os.path.join(host_dir, name)
        if not os.path.exists(path):
            return {}
        out = {}
        for line in open(path):
            f = line.split()
            if len(f) >= 3:
                # name rx_packets rx_dropped [xdp id] rx_over_errors: without a program the id is missing, so
                # rx_over_errors is the 4th field, and with one the 5th.
                xdp = f[3] if len(f) > 4 else None
                over = int(f[-1]) if len(f) > 3 else 0
                out[f[0]] = (int(f[1]), int(f[2]) + over, xdp, over)
        return out
    start, end = read("nic-start.txt"), read("nic-end.txt")
    if not start:
        return None
    out = {}
    for iface, (rx0, drop0, xdp0, over0) in start.items():
        if iface not in end:
            out[iface] = {"xdp_start": xdp0, "gone_at_end": True}
            continue
        rx1, drop1, xdp1, over1 = end[iface]
        rx, drop = rx1 - rx0, drop1 - drop0
        out[iface] = {"rx_packets": rx, "rx_dropped": drop, "rx_over_errors": over1 - over0, "drop_share": round(drop / (rx + drop), 4) if rx + drop > 0 else 0,
                      "xdp_start": xdp0, "xdp_end": xdp1}
    for iface in end:
        if iface not in start:
            out[iface] = {"xdp_end": end[iface][2], "new_at_end": True}
    guard = os.path.join(host_dir, "guard.txt")
    if os.path.exists(guard):
        out["guard"] = open(guard).read().strip()
    return out


def irq_layout(host_dir):
    path = os.path.join(host_dir, "irq.txt")
    if not os.path.exists(path):
        return None
    out = {line.split()[0]: line.split()[1] for line in open(path) if len(line.split()) == 2}
    ib = os.path.join(host_dir, "irqbalance.txt")
    if os.path.exists(ib):
        out["irqbalance"] = open(ib).read().strip()
    return out


def fair_summary(host_dir):
    """Per worker address: throughput, retransmits and TCP round trip from iperf3, and ping round trips."""
    out = {}
    for path in glob.glob(os.path.join(host_dir, "iperf-heavy-*.json")) + glob.glob(os.path.join(host_dir, "iperf-light-*.json")):
        kind, ip = os.path.basename(path)[6:-5].split("-", 1)
        w = out.setdefault(ip, {"kind": kind})
        try:
            data = json.load(open(path))
        except ValueError:
            w["error"] = "not JSON"
            continue
        if data.get("error"):
            w["error"] = data["error"]
        end = data.get("end", {})
        if "sum_received" in end:
            w["gbps"] = round(end["sum_received"]["bits_per_second"] / 1e9, 3)
            w["retransmits"] = end["sum_sent"].get("retransmits", 0)
        rtts = [st["sender"].get("mean_rtt") for st in end.get("streams", []) if st.get("sender", {}).get("mean_rtt")]
        if rtts:
            w["tcp_mean_rtt_ms"] = round(statistics.mean(rtts) / 1000, 3)
    for path in glob.glob(os.path.join(host_dir, "ping-light-*.txt")):
        ip = os.path.basename(path)[11:-4]
        times, sent = [], 0
        for line in open(path):
            m = re.search(r"icmp_seq=\d+ .*time=([\d.]+) ms", line)
            if m:
                times.append(float(m.group(1)))
            m = re.search(r"(\d+) packets transmitted", line)
            if m:
                sent = int(m.group(1))
        w = out.setdefault(ip, {"kind": "light"})
        w["ping_ms"] = summarize(times)
        if sent:
            w["ping_loss_pct"] = round(100.0 * (1 - len(times) / sent), 2)
    return out or None


def churn_summary(host_dir):
    path = os.path.join(host_dir, "churn.json")
    if not os.path.exists(path):
        return None
    try:
        return json.load(open(path))
    except ValueError:
        return {"error": "not JSON"}


def peers(host_dir):
    path = os.path.join(host_dir, "peers.txt")
    if not os.path.exists(path):
        return None
    seen = set()
    for line in open(path):
        parts = line.split()
        if len(parts) < 5 or parts[0] in ("LISTEN", "UNCONN") or parts[4].startswith("*"):
            continue
        address = parts[4].rsplit(":", 1)[0].strip("[]")
        seen.add(address[7:] if address.startswith("::ffff:") else address)
    return sorted(seen)


def analyze(run_dir):
    meta = json.load(open(os.path.join(run_dir, "meta.json")))
    load_at = int(meta["load_at"])
    duration = int(meta["DURATION"])
    end = load_at + duration
    if meta.get("stopped_at"):
        end = min(end, int(float(meta["stopped_at"])))
    steady = (load_at + SETTLE, end - 1)
    # The last 30 s of load: after a burst allowance runs out, this is the sustained rate.
    tail = (max(load_at + SETTLE, end - 31), end - 1)
    whole = (int(meta["start"]), load_at + duration + int(meta["POST"]))
    handover_at = float(meta["handover_sent"]) if meta.get("handover_sent") else None
    roles = {meta["owner"]: "owner", meta["standby"]: "standby"}
    for g in meta["generators"].split():
        roles[g] = "generator"
    out = {"meta": meta, "hosts": {}}
    for host_dir in sorted(glob.glob(os.path.join(run_dir, "i-*"))):
        instance = os.path.basename(host_dir)
        role = roles.get(instance, "receiver")
        host = {"role": role, "interfaces": read_interfaces(host_dir)}
        kernel = os.path.join(host_dir, "kernel.txt")
        if os.path.exists(kernel):
            host["kernel"] = open(kernel).read().strip()
        enapoll = os.path.join(host_dir, "enapoll.csv.gz")
        if os.path.exists(enapoll):
            by_iface = read_enapoll(enapoll)
            host["steady"] = {}
            host["whole_run"] = {}
            for iface, rows in by_iface.items():
                label = iface
                eni = host["interfaces"].get(iface, {}).get("eni")
                if eni == meta["shared_eni"]:
                    label += " (shared)"
                host["steady"][label] = rates(rows, *steady)
                host["whole_run"][label] = rates(rows, *whole)
                host.setdefault("tail_30s", {})[label] = rates(rows, *tail)
                reads = [r["read_ns"] / 1000 for r in rows]
                host.setdefault("read_us", {})[label] = summarize(reads)
                if role in ("owner", "standby"):
                    host.setdefault("timeline", {})[label] = per_second(rows, load_at)
                    host.setdefault("counter_changes", {})[label] = counter_changes(rows, load_at, end + 5)
                    # Every run has a start and a stop edge, and on/off runs one pair per cycle. linklocal.sh
                    # records the exact start and stop of each burst of queries.
                    edges = load_edges(rows)
                    edges_file = os.path.join(host_dir, "edges.txt")
                    if os.path.exists(edges_file):
                        edges = [(kind, float(t)) for kind, t in (line.split() for line in open(edges_file))]
                    host.setdefault("load_edges", {})[label] = len(edges)
                    host.setdefault("edge_delays", {})[label] = edge_delays(rows, edges)
                if role == "receiver" and handover_at:
                    host.setdefault("receive_gap", {})[label] = receive_gap(rows, load_at + 1, load_at + duration - 1)
            if role in ("owner", "standby"):
                total_rx = sum((v or {}).get("rx_pps", 0) for v in host["steady"].values())
                total_tx = sum((v or {}).get("tx_pps", 0) for v in host["steady"].values())
                host["steady_total"] = {"rx_pps": total_rx, "tx_pps": total_tx, "rx_plus_tx_pps": total_rx + total_tx}
        host["cpu"] = cpu_usage(host_dir, *steady)
        if role in ("owner", "standby") and host.get("steady_total") and host["cpu"]:
            rx = host["steady_total"]["rx_pps"]
            if rx > 1000:
                host["cpu_ns_per_forwarded_packet"] = round(host["cpu"]["busy_cores"] * 1e9 / rx)
                host["softirq_ns_per_forwarded_packet"] = round(host["cpu"]["softirq_cores"] * 1e9 / rx)
        if host["cpu"] and host["cpu"]["cpus"]:
            per_cpu = [100 - v["idle"] - v["iowait"] for k, v in host["cpu"]["cpus"].items() if k != "cpu"]
            host["cpu"]["busiest_cpu_pct"] = round(max(per_cpu), 1) if per_cpu else None
        host["pacing_status"] = pacing_status(host_dir)
        host["pacing_limits"] = pacing_limits(host_dir, load_at)
        host["bpf"] = bpf_stats(host_dir)
        host["conntrack"] = conntrack_stats(host_dir, *steady)
        host["irq"] = irq_layout(host_dir)
        host["nic"] = nic_drops(host_dir)
        host["threaded"] = threaded(host_dir)
        host["fair"] = fair_summary(host_dir)
        host["churn"] = churn_summary(host_dir)
        host["iperf"] = iperf_summary(host_dir)
        host["ping"] = ping_summary(host_dir, load_at, handover_at)
        host["journal"] = journal_summary(host_dir)
        host["receiver_saw_sources"] = peers(host_dir)
        out["hosts"][instance] = {k: v for k, v in host.items() if v is not None}
    gens = [h for h in out["hosts"].values() if h["role"] == "generator" and h.get("iperf")]
    out["iperf_total"] = {
        "sent_gbps": round(sum(h["iperf"]["sent_gbps"] for h in gens), 3),
        "received_gbps": round(sum(h["iperf"]["received_gbps"] for h in gens), 3),
        "retransmits": sum(h["iperf"]["retransmits"] for h in gens),
        "errors": [e for h in gens for e in h["iperf"]["errors"]],
    }
    seen = [h["receiver_saw_sources"] for h in out["hosts"].values() if h.get("receiver_saw_sources") is not None]
    if seen:
        out["sources_ok"] = seen[0] == [meta["shared_private_ip"]]
    flood = os.path.join(run_dir, "flood.json")
    if os.path.exists(flood):
        out["flood"] = json.load(open(flood))
    return out


def brief(path):
    s = json.load(open(path))
    owner = s["hosts"].get(s["meta"]["owner"], {})
    parts = [s["meta"]["run"]]
    for label, r in (owner.get("steady") or {}).items():
        if r:
            drops = ",".join("%s=%d/s" % (c.split("_allowance")[0], r[c + "_per_s"]) for c in COUNTERS if r.get(c + "_per_s"))
            parts.append("%s rx %d pps %.2f Gbps tx %d pps %.2f Gbps %s" % (label, r["rx_pps"], r["rx_gbps"], r["tx_pps"], r["tx_gbps"], drops))
    if owner.get("cpu"):
        parts.append("busy %.2f cores soft %.2f" % (owner["cpu"]["busy_cores"], owner["cpu"]["softirq_cores"]))
    if "cpu_ns_per_forwarded_packet" in owner:
        parts.append("%d ns/pkt" % owner["cpu_ns_per_forwarded_packet"])
    parts.append("iperf %.2f Gbps retr %d" % (s["iperf_total"]["received_gbps"], s["iperf_total"]["retransmits"]))
    if s["iperf_total"]["errors"]:
        parts.append("ERRORS %s" % s["iperf_total"]["errors"][:2])
    if "sources_ok" in s:
        parts.append("sources_ok=%s" % s["sources_ok"])
    print(" | ".join(parts))


if __name__ == "__main__":
    if sys.argv[1] == "--brief":
        brief(sys.argv[2])
    else:
        json.dump(analyze(sys.argv[1]), sys.stdout, indent=1)
        print()
