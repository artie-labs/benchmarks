#!/usr/bin/env python3
"""Summarizes a box/prof.sh perf script (script.txt.gz): samples per command, and for chosen commands how many
samples ran softirq work, entered through which path (a system call, an interrupt, or a kernel thread), the system
calls in their stacks, their hottest functions and stacks.

Usage: prof-summary.py <script.txt.gz> [comm ...]   (default comms: natpair, conntrackd)
"""
import collections
import gzip
import re
import sys

SOFTIRQ = re.compile(r"^(handle_softirqs|__do_softirq|net_rx_action)$")


def samples(path):
    header, frames = None, []
    for line in gzip.open(path, "rt", errors="replace"):
        line = line.rstrip("\n")
        if not line.strip():
            if header:
                yield header, frames
            header, frames = None, []
        elif line.startswith((" ", "\t")):
            parts = line.split(None, 1)
            sym = parts[1] if len(parts) > 1 else "?"
            frames.append(re.sub(r"\+0x[0-9a-f]+$", "", sym.split(" (")[0]))
        else:
            header = line
    if header:
        yield header, frames


def comm_of(header):
    # "<comm> <pid>/<tid> [cpu] time:", where comm may hold spaces.
    m = re.match(r"^\s*(.*?)\s+(\d+)/(\d+)\s+\[(\d+)\]", header)
    return (m.group(1), m.group(2), m.group(3), m.group(4)) if m else (header.split()[0], "?", "?", "?")


def entry(frames):
    names = set(frames)
    if any(f.startswith("__arm64_sys_") or f == "invoke_syscall" for f in frames):
        return "syscall"
    if names & {"el0_interrupt", "el1_interrupt", "el0t_64_irq", "el1h_64_irq", "irq_exit_rcu", "__irq_exit_rcu"}:
        return "interrupt"
    if names & {"ret_from_fork", "kthread"}:
        return "kthread"
    if not frames or not frames[0].startswith(("0x", "[")) and all(not f.startswith(("el0", "el1")) for f in frames):
        return "user"
    return "other"


def main():
    path = sys.argv[1]
    comms = sys.argv[2:] or ["natpair", "conntrackd"]
    per_comm = collections.Counter()
    per_cpu_comm = collections.Counter()
    by_comm = collections.defaultdict(list)
    total = 0
    for header, frames in samples(path):
        comm, _, _, cpu = comm_of(header)
        key = re.sub(r"/\d+$", "/N", comm)
        per_comm[key] += 1
        per_cpu_comm[(cpu, key)] += 1
        total += 1
        if comm in comms or key in comms:
            by_comm[key].append(frames)
    print(f"{total} samples")
    for comm, n in per_comm.most_common(15):
        print(f"  {comm:24s} {n:7d} {100 * n / total:5.1f}%")
    for c in comms:
        stacks = by_comm.get(c, [])
        if not stacks:
            continue
        n = len(stacks)
        soft = [s for s in stacks if any(SOFTIRQ.match(f) for f in s)]
        print(f"\n== {c}: {n} samples ({100 * n / total:.1f}% of all), softirq in stack: {len(soft)} ({100 * len(soft) / n:.1f}%)")
        print("  entry of all samples:", dict(collections.Counter(entry(s) for s in stacks).most_common()))
        print("  entry of softirq samples:", dict(collections.Counter(entry(s) for s in soft).most_common()))
        sys_all = collections.Counter(next((f for f in s if f.startswith("__arm64_sys_")), "-") for s in stacks)
        sys_soft = collections.Counter(next((f for f in s if f.startswith("__arm64_sys_")), "-") for s in soft)
        print("  system call in stack (all):", ", ".join(f"{k} {v}" for k, v in sys_all.most_common(12)))
        print("  system call in stack (softirq):", ", ".join(f"{k} {v}" for k, v in sys_soft.most_common(12)))
        # What led into softirq work. On arm64 softirqs run on the IRQ stack, entered through do_softirq_own_stack:
        # from do_softirq <- __local_bh_enable_ip when the task re-enabled bottom halves, or from irq_exit. The four
        # frames past that show who did it, such as fpsimd_restore_current_state on the return to user mode.
        into = collections.Counter()
        for s in soft:
            if "do_softirq_own_stack" in s:
                i = s.index("do_softirq_own_stack")
                into[" <- ".join(s[i + 1 : i + 3]) + " | " + " <- ".join(s[i + 3 : i + 7])] += 1
            else:
                i = max(i for i, f in enumerate(s) if SOFTIRQ.match(f))
                into["(no own stack) " + " <- ".join(s[i + 1 : i + 4])] += 1
        print("  into softirq from:")
        for k, v in into.most_common(10):
            print(f"    {100 * v / n:5.1f}% {k}")
        leaf = collections.Counter(s[0] if s else "?" for s in stacks)
        print("  hottest functions (self):", ", ".join(f"{k} {100 * v / n:.1f}%" for k, v in leaf.most_common(15)))
        folded = collections.Counter(";".join(reversed(s[:10])) for s in stacks)
        print("  top stacks (outermost first, 10 frames from the leaf):")
        for k, v in folded.most_common(10):
            print(f"    {100 * v / n:5.1f}% {k}")
    print("\nper CPU:", ", ".join(f"cpu{c} {k} {v}" for (c, k), v in sorted(per_cpu_comm.items()) if v > total * 0.02))


if __name__ == "__main__":
    main()
