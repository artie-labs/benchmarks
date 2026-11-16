#!/usr/bin/env python3
"""One line per run from the NATs' journals and the run summaries: takeovers, counted failed probe rounds, the longest
run of them on a serving NAT, #15's congested-path checks, guard engagements, ping loss and the shared ENI's rates.

A failed round counts toward stepping down unless it was congested (#15) or the connection table was full (#12). Each
counted failure is logged, and a passing round after one changes the logged state, so it is logged too.

Usage: failed-rounds.py <journals dir> <results dir> <run>...  (journals laid out as <run>/<instance>/journal.txt)
"""
import glob, json, os, re, sys
runs_dir, results_dir = sys.argv[1], sys.argv[2]
for run in sys.argv[3:]:
    counted = longest = congested_lines = alive = acquired = engaged = 0
    for path in sorted(glob.glob(f"{runs_dir}/{run}/*/journal.txt")):
        streak = 0
        for line in open(path, errors="replace"):
            if "ownership acquired" in line:
                acquired += 1
            if "overload guard engaged" in line:
                engaged += 1
            if "the health probe failed, but the path is alive" in line:
                alive += 1
            if '"health round"' not in line:
                continue
            m = re.search(r"\{.*\}", line)
            r = json.loads(m.group(0))
            if r.get("congested"):
                congested_lines += 1
            if not r["healthy"] and not r.get("table_full") and not r.get("congested"):
                counted += 1
                if r.get("serving"):
                    streak += 1
                    longest = max(longest, streak)
            else:
                streak = 0
    summary = glob.glob(f"{results_dir}/{run}.json")
    loss = fwd = rx = "?"
    if summary:
        s = json.load(open(summary[0]))
        m = s["meta"]
        sh = (s["hosts"].get(m["owner"], {}).get("steady") or {}).get("ens6 (shared)") or {}
        fwd, rx = sh.get("tx_pps"), sh.get("rx_pps")
        ping = next((h["ping"] for h in s["hosts"].values() if h.get("ping")), {}) or {}
        loss = ping.get("loss_pct")
        gbps = (s.get("iperf_total") or {}).get("received_gbps")
    print(f"{run:52s} acquired {acquired} counted_fail {counted} max_in_a_row {longest} path_alive {alive} "
          f"congested_lines {congested_lines} engaged {engaged} ping_loss {loss}% rx {rx} fwd {fwd} iperf {gbps}")
