#!/usr/bin/env python3
"""One line per run summary: shared ENI rate, daemon CPU, lease, DNS and probe failures, takeovers, ping loss.

Usage: run-brief.py <results/*.json ...>
"""
import json, sys
for f in sys.argv[1:]:
    r = json.load(open(f)); m = r["meta"]; h = r["hosts"]
    o = h.get(m["owner"], {}); s = h.get(m["standby"], {})
    c = {}
    for nat in (o, s):
        for k, v in ((nat.get("journal") or {}).get("counts") or {}).items():
            c[k] = c.get(k, 0) + v
    st = (o.get("steady") or {}).get("ens6 (shared)") or {}
    procs = (o.get("cpu") or {}).get("procs", {})
    ping = next((x["ping"] for x in h.values() if x.get("ping")), {}) or {}
    print(f'{m["name"]:34s} {o.get("kernel","?")[:7]} ens6 rx {st.get("rx_gbps")} Gbps {st.get("rx_pps")} pps miss {st.get("missing_s")}s | natpair {procs.get("natpair",{}).get("cpu_pct")}% ctd {procs.get("conntrackd",{}).get("cpu_pct")}% | lease {c.get("lease_store_unreachable")} dns {c.get("dns_or_probe_timeout")} probe {c.get("probe_errors")} acq {c.get("ownership_acquired")} ended {c.get("stepped_down")} alive {c.get("path_alive")} cong {c.get("congested_rounds")} | ping loss {ping.get("loss_pct")}% gap {ping.get("longest_gap_s")}s | iperf {r.get("iperf_total",{}).get("received_gbps")}')
