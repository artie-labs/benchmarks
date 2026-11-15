#!/usr/bin/env python3
"""One line per irq-ab run: throughput, shared ENI packet rate, the owner's per-CPU busy %, where the shared ENI's
queue interrupts and napi/ threads were, allowance drops, and journal counts. Usage: irq-table.py <summary.json>..."""
import json
import sys


def main():
    for path in sys.argv[1:]:
        s = json.load(open(path))
        meta = s["meta"]
        owner = s["hosts"].get(meta["owner"], {})
        standby = s["hosts"].get(meta["standby"], {})
        shared = next((v for k, v in (owner.get("steady") or {}).items() if "shared" in k), None) or {}
        cpus = (owner.get("cpu") or {}).get("cpus", {})
        per_cpu = " ".join("%s:%.0f" % (k, 100 - v["idle"] - v["iowait"]) for k, v in sorted(cpus.items()) if k != "cpu")
        pl = owner.get("placement") or {}
        irq = " ".join("%s>%s" % (k.replace("-Tx-Rx", ""), "/".join("%s:%.0f%%" % (c, 100 * x) for c, x in v.items()))
                       for k, v in pl.get("irq", {}).items())
        napi = " ".join("%s@%s=%s%%" % (k.split("/")[1], "/".join("%s:%.0f" % (c, 100 * x) for c, x in v["on_cpu"].items()), v["cpu_pct"])
                        for k, v in pl.get("napi", {}).items())
        drops = {c: shared.get(c + "_per_s") for c in ("bw_out_allowance_exceeded", "pps_allowance_exceeded") if shared.get(c + "_per_s")}
        j = {}
        for h in (owner, standby):
            for k, v in ((h.get("journal") or {}).get("counts") or {}).items():
                if isinstance(v, int) and k in ("lease_store_unreachable", "dns_or_probe_timeout", "ownership_acquired", "stepped_down", "probe_errors"):
                    j[k] = j.get(k, 0) + v
        print("%s | %.2f Gbps | rx %dk pps | busy %s | stacked %s | irqbalance %s | %s | %s | drops %s | %s | sources_ok %s" % (
            meta["run"], s["iperf_total"]["received_gbps"], shared.get("rx_pps", 0) / 1000, per_cpu, pl.get("stacked"),
            pl.get("irqbalance_start"), irq, napi, drops, j, s.get("sources_ok")))


if __name__ == "__main__":
    main()
