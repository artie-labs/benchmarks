#!/usr/bin/env python3
"""Groups run summaries in results/ by run name, without the timestamp and round suffix, and prints the median and
range of the numbers RESULTS.md uses. Writes the same to results/summary.json.

Usage: aggregate.py [results dir]
"""
import glob
import json
import os
import re
import statistics
import sys

COUNTERS = ["bw_in_allowance_exceeded", "bw_out_allowance_exceeded", "pps_allowance_exceeded",
            "conntrack_allowance_exceeded", "linklocal_allowance_exceeded"]


def group_name(run):
    name = re.sub(r"^\d{8}T\d{6}Z-", "", run)
    return re.sub(r"-\d$", "", name)


def owner_metrics(s, window):
    owner = s["hosts"].get(s["meta"]["owner"], {})
    m = {}
    rates = owner.get(window) or {}
    for label, r in rates.items():
        if not r:
            continue
        side = "shared" if "shared" in label else "own"
        for k in ("rx_pps", "tx_pps", "rx_gbps", "tx_gbps"):
            m["%s_%s" % (side, k)] = r[k]
        for c in COUNTERS:
            if r.get(c + "_per_s"):
                m["%s_%s_per_s" % (side, c.replace("_allowance_exceeded", "_drops"))] = r[c + "_per_s"]
        if r.get("missing_s"):
            m["%s_missing_s" % side] = r["missing_s"]
    m["forwarded_pps"] = sum((r or {}).get("rx_pps", 0) for r in rates.values())
    m["rx_plus_tx_pps"] = sum((r or {}).get("rx_pps", 0) + (r or {}).get("tx_pps", 0) for r in rates.values())
    cpu = owner.get("cpu") or {}
    if cpu:
        m["busy_cores"] = cpu.get("busy_cores")
        m["softirq_cores"] = cpu.get("softirq_cores")
        for proc in ("conntrackd", "natpair"):
            if proc in cpu.get("procs", {}):
                m[proc + "_cpu_pct"] = cpu["procs"][proc]["cpu_pct"]
    if "cpu_ns_per_forwarded_packet" in owner:
        m["ns_per_packet"] = owner["cpu_ns_per_forwarded_packet"]
    for label, r in (owner.get("read_us") or {}).items():
        if "shared" in label and r:
            m["read_us_p50"] = r["median"]
            m["read_us_p90"] = r["p90"]
    for label, changes in (owner.get("counter_changes") or {}).items():
        side = "shared" if "shared" in label else "own"
        for c, v in changes.items():
            short = c.replace("_allowance_exceeded", "")
            if v.get("gap_ms"):
                m["%s_%s_change_gap_ms" % (side, short)] = v["gap_ms"]["median"]
                m["%s_%s_changes" % (side, short)] = v["changes"]
    for label, delays in (owner.get("edge_delays") or {}).items():
        side = "shared" if "shared" in label else "own"
        for c, v in delays.items():
            short = c.replace("_allowance_exceeded", "")
            if v.get("last_change_after_load_stop_ms"):
                m["%s_%s_stale_after_stop_ms" % (side, short)] = v["last_change_after_load_stop_ms"]["median"]
            if v.get("first_change_after_load_start_ms"):
                m["%s_%s_first_after_start_ms" % (side, short)] = v["first_change_after_load_start_ms"]["median"]
    journal = {}
    for h in s["hosts"].values():
        for k, v in ((h.get("journal") or {}).get("counts") or {}).items():
            journal[k] = journal.get(k, 0) + v
    for k in ("lease_store_unreachable", "stepped_down", "ownership_acquired", "conntrackd_netlink_loss"):
        if journal.get(k):
            m["journal_" + k] = journal[k]
    m["iperf_gbps"] = s["iperf_total"]["received_gbps"]
    m["retransmits"] = s["iperf_total"]["retransmits"]
    for h in s["hosts"].values():
        if h.get("ping"):
            m["ping_loss_pct"] = h["ping"].get("loss_pct")
            m["ping_longest_gap_s"] = h["ping"].get("longest_gap_s")
        for label, g in (h.get("receive_gap") or {}).items():
            if g:
                m["receiver_gap_s"] = g["longest_gap_s"]
        if h["role"] == "generator":
            for r in (h.get("steady") or {}).values():
                for c in COUNTERS:
                    if r and r.get(c):
                        m["generator_" + c.replace("_allowance_exceeded", "_drops")] = m.get("generator_" + c.replace("_allowance_exceeded", "_drops"), 0) + r[c]
    if "sources_ok" in s:
        m["sources_ok"] = s["sources_ok"]
    return m


def main():
    results = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "results")
    groups = {}
    for path in sorted(glob.glob(os.path.join(results, "2*.json"))):
        s = json.load(open(path))
        window = "tail_30s" if "-limit-" in path or "-burst" in path else "steady"
        groups.setdefault(group_name(s["meta"]["run"]), []).append(owner_metrics(s, window))
    summary = {}
    for name, runs in groups.items():
        keys = sorted({k for r in runs for k in r})
        out = {"runs": len(runs)}
        for k in keys:
            vals = [r[k] for r in runs if isinstance(r.get(k), (int, float)) and not isinstance(r.get(k), bool)]
            if vals:
                out[k] = {"median": round(statistics.median(vals), 3), "min": min(vals), "max": max(vals)}
            elif all(isinstance(r.get(k), bool) for r in runs if k in r):
                out[k] = all(r[k] for r in runs if k in r)
        summary[name] = out
    json.dump(summary, open(os.path.join(results, "summary.json"), "w"), indent=1)
    for name, out in summary.items():
        print("%s (%d runs)" % (name, out["runs"]))
        for k, v in out.items():
            if k == "runs":
                continue
            if isinstance(v, dict):
                print("  %-40s %s  [%s .. %s]" % (k, v["median"], v["min"], v["max"]))
            else:
                print("  %-40s %s" % (k, v))


if __name__ == "__main__":
    main()
