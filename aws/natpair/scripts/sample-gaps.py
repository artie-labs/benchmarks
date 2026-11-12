#!/usr/bin/env python3
"""Prints how often each allowance counter changed in a standalone enapoll sample, such as the 1 ms sample that
jobs/2e-drop-1ms-window.sh takes once the burst is spent.

Usage: sample-gaps.py <enapoll csv.gz>
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "box"))
import analyze  # noqa: E402

by_iface = analyze.read_enapoll(sys.argv[1])
out = {}
for iface, rows in by_iface.items():
    changes = analyze.counter_changes(rows, rows[0]["t"], rows[-1]["t"])
    for c in changes.values():
        c.pop("times", None)
    out[iface] = {
        "samples": len(rows),
        "seconds": round(rows[-1]["t"] - rows[0]["t"], 2),
        "read_us": analyze.summarize([r["read_ns"] / 1000 for r in rows]),
        "rates": analyze.rates(rows, rows[0]["t"], rows[-1]["t"]),
        "changes": changes,
    }
json.dump(out, sys.stdout, indent=1)
print()
