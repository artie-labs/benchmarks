#!/usr/bin/env python3
"""One line per NAT for each sampled copy in jobs/ctsize.sh (box/ctnat.sh sample): a full copy to a restarted
standby conntrackd (<name> ending -resync) or a takeover (-takeover).

The copy starts when the receiving NAT's conntrackd restarts or it steps down, and ends a second after the copy first
holds 98% of its final size, so a copy that lands within a second shows as about 2 s. Bytes and packets are the sending NAT's primary interface (ens5) over the
copy. CPU is in cores, averaged over the copy and at its busiest second. Memory is the lowest MemAvailable and the
highest conntrackd and natpair RSS over the whole sample.

Usage: ctsize-summary.py <dir holding <name>/<instance>.csv>...
"""
import csv, glob, os, sys

HZ = 100


def load(path):
    rows = []
    for r in csv.DictReader(open(path)):
        try:
            row = {k: (float(v) if k != "role" and v not in ("", None) else v) for k, v in r.items()}
        except ValueError:
            continue
        rows.append(row)
    return rows


def window_rate(rows, a, b, key):
    return rows[b][key] - rows[a][key]


def cores(rows, a, b, busy="busy_ticks", idle="idle_ticks", ncpu=2):
    """Average busy cores between rows a and b, and the busiest one-second step."""
    def step(i, j):
        db, di = rows[j][busy] - rows[i][busy], rows[j][idle] - rows[i][idle]
        return ncpu * db / (db + di) if db + di > 0 else 0.0
    peak = max((step(i, i + 1) for i in range(a, b)), default=0.0)
    return step(a, b), peak


def proc_cores(rows, a, b, key):
    dt = rows[b]["t"] - rows[a]["t"]
    peak = max(((rows[i + 1][key] - rows[i][key]) / HZ / max(rows[i + 1]["t"] - rows[i]["t"], 1e-3)
                for i in range(a, b)), default=0.0)
    return ((rows[b][key] - rows[a][key]) / HZ / dt if dt > 0 else 0.0), peak


def main():
    for base in sys.argv[1:]:
        for name in sorted(os.listdir(base)):
            files = sorted(glob.glob(os.path.join(base, name, "*.csv")))
            data = {os.path.basename(f)[:-4]: load(f) for f in files}
            data = {k: v for k, v in data.items() if len(v) > 3}
            if len(data) != 2:
                continue
            # The receiver of the copy is the NAT that is standby at the end.
            recv = next((k for k, v in data.items() if v[-1]["role"] == "standby"), None)
            send = next((k for k in data if k != recv), None)
            if recv is None or send is None:
                continue
            r, s = data[recv], data[send]
            ext = [row["ctd_external"] if row["ctd_external"] != "" else None for row in r]
            # Start: the receiver's conntrackd restarted (its CPU time starts over) or it stepped down. The copy
            # itself often lands within a second, so the window runs from the row before to the row after.
            start = 0
            for i in range(1, len(r)):
                if r[i]["ctd_ticks"] < r[i - 1]["ctd_ticks"] or (r[i]["role"] != r[i - 1]["role"]):
                    start = i - 1
                    break
            final = max((e for e in ext[start + 2:] if e is not None), default=0)
            done = next((i for i in range(start + 1, len(r)) if ext[i] is not None and ext[i] >= 0.98 * final), len(r) - 1)
            done = min(done + 1, len(r) - 1)
            t0, t1 = r[start]["t"], r[done]["t"]
            sa = min(range(len(s)), key=lambda i: abs(s[i]["t"] - t0))
            sb = min(range(len(s)), key=lambda i: abs(s[i]["t"] - t1))
            sb = max(sb, sa + 1)
            sender_table = max(row["count"] for row in s[sa:sb + 1])
            print(f"{name}: copy {final:.0f} of the sender's table {sender_table:.0f} "
                  f"({100 * final / max(sender_table, 1):.1f}%) in {t1 - t0:.0f} s, "
                  f"sender ens5 sent {window_rate(s, sa, sb, 'ens5_tx_bytes') / 1e6:.0f} MB "
                  f"{window_rate(s, sa, sb, 'ens5_tx_packets') / 1e3:.0f}k packets")
            ra = min(range(len(r)), key=lambda i: abs(r[i]["t"] - t0))
            # A restarted conntrackd's CPU time starts over: count it from its first row.
            if r[ra + 1]["ctd_ticks"] < r[ra]["ctd_ticks"]:
                ra += 1
            rb = max(min(range(len(r)), key=lambda i: abs(r[i]["t"] - t1)), ra + 1)
            for label, rows, a, b, nat in (("sender", s, sa, sb, send), ("receiver", r, ra, rb, recv)):
                avg, peak = cores(rows, a, b)
                cavg, cpeak = proc_cores(rows, a, b, "ctd_ticks")
                print(f"  {label} {nat} ({rows[0]['role']} -> {rows[-1]['role']}): CPU {avg:.2f} cores (peak {peak:.2f}),"
                      f" conntrackd {cavg:.2f} (peak {cpeak:.2f}); min MemAvailable"
                      f" {min(x['memavail_kb'] for x in rows) / 1024:.0f} MB, max conntrackd RSS"
                      f" {max(x['ctd_rss_kb'] for x in rows) / 1024:.0f} MB, max natpair RSS"
                      f" {max(x['natpair_rss_kb'] for x in rows) / 1024:.0f} MB, max table {max(x['count'] for x in rows):.0f}")


if __name__ == "__main__":
    main()
