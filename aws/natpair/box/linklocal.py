#!/usr/bin/env python3
"""Sends DNS queries to the VPC resolver at a fixed rate in on/off cycles, to trip linklocal_allowance_exceeded (AWS
allows 1024 packets a second per ENI to link-local services). Writes "on <unix time>" and "off <unix time>" lines to
the edges file, so the counter's lag behind the real start and stop can be measured on one clock.

Usage: linklocal.py --rate 4000 --on 2 --off 3 --cycles 12 --edges edges.txt
"""
import argparse
import socket
import struct
import time


def query(qid):
    header = struct.pack(">HHHHHH", qid & 0xFFFF, 0x0100, 1, 0, 0, 0)
    name = b"".join(bytes([len(p)]) + p for p in b"amazon.com".split(b".")) + b"\x00"
    return header + name + struct.pack(">HH", 1, 1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rate", type=int, default=4000)
    p.add_argument("--on", type=float, default=2)
    p.add_argument("--off", type=float, default=3)
    p.add_argument("--cycles", type=int, default=12)
    p.add_argument("--target", default="169.254.169.253")
    p.add_argument("--edges", default="edges.txt")
    args = p.parse_args()

    # One socket, so the NAT's own connection table holds one entry, not one per query.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setblocking(False)
    sock.connect((args.target, 53))
    edges = open(args.edges, "w")
    qid = 0
    start = time.time()
    for cycle in range(args.cycles):
        on_at = start + cycle * (args.on + args.off)
        time.sleep(max(0.0, on_at - time.time()))
        edges.write("on %.6f\n" % time.time())
        sent = 0
        t0 = time.time()
        while True:
            now = time.time()
            if now - t0 >= args.on:
                break
            due = int((now - t0) * args.rate)
            while sent < due:
                try:
                    sock.send(query(qid))
                except (BlockingIOError, ConnectionRefusedError):
                    pass
                sent += 1
                qid += 1
            # Drain replies so the socket buffer never fills.
            try:
                while sock.recv(512):
                    pass
            except (BlockingIOError, ConnectionRefusedError):
                pass
            time.sleep(0.0005)
        edges.write("off %.6f\n" % time.time())
        edges.flush()
    edges.close()


if __name__ == "__main__":
    main()
