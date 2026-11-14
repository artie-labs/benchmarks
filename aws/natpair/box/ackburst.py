#!/usr/bin/env python3
"""Sends TCP ACKs without a connection to one address and port, and counts the resets that come back.

Usage: ackburst.py <dst ip> <dst port> <burst> <burst pps> <tail seconds> <tail pps>

Sends <burst> ACKs at <burst pps>, then ACKs at <tail pps> for <tail seconds>, all from this host's address with
random source ports. A raw socket on the same host sees every reset from <dst ip>:<dst port>. Prints JSON: resets
during the burst and the 0.5 s after it, and resets per second of the tail.
"""
import json
import random
import socket
import struct
import sys
import threading
import time


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack(f"!{len(data) // 2}H", data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def ack(src, dst, sport, dport):
    seq, ack_no = random.getrandbits(32), random.getrandbits(32)
    hdr = struct.pack("!HHIIBBHHH", sport, dport, seq, ack_no, 5 << 4, 0x10, 64240, 0, 0)
    pseudo = socket.inet_aton(src) + socket.inet_aton(dst) + struct.pack("!BBH", 0, socket.IPPROTO_TCP, len(hdr))
    return hdr[:16] + struct.pack("!H", checksum(pseudo + hdr)) + hdr[18:]


def main():
    dst, dport, burst, burst_pps, tail_s, tail_pps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), \
        float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.connect((dst, dport))
    src = probe.getsockname()[0]
    probe.close()

    recv = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP)
    recv.settimeout(0.2)
    resets = []
    stop = threading.Event()

    def listen():
        while not stop.is_set():
            try:
                pkt, addr = recv.recvfrom(65535)
            except socket.timeout:
                continue
            if addr[0] != dst:
                continue
            ihl = (pkt[0] & 0x0F) * 4
            sport, _, _, _, _, flags = struct.unpack("!HHIIBB", pkt[ihl:ihl + 14])
            if sport == dport and flags & 0x04:
                resets.append(time.monotonic())

    t = threading.Thread(target=listen)
    t.start()
    send = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP)
    start = time.monotonic()
    for i in range(burst):
        send.sendto(ack(src, dst, random.randint(20000, 60000), dport), (dst, 0))
        time.sleep(max(0.0, start + (i + 1) / burst_pps - time.monotonic()))
    burst_end = time.monotonic()
    tail_start = burst_end + 0.5
    time.sleep(0.5)
    sent_tail = 0
    while time.monotonic() < tail_start + tail_s:
        send.sendto(ack(src, dst, random.randint(20000, 60000), dport), (dst, 0))
        sent_tail += 1
        time.sleep(max(0.0, tail_start + sent_tail / tail_pps - time.monotonic()))
    time.sleep(1)
    stop.set()
    t.join()
    in_burst = sum(1 for r in resets if r < tail_start)
    per_second = [sum(1 for r in resets if tail_start + k <= r < tail_start + k + 1) for k in range(int(tail_s))]
    print(json.dumps({
        "src": src, "dst": f"{dst}:{dport}", "burst_sent": burst, "burst_seconds": round(burst_end - start, 3),
        "burst_resets": in_burst, "tail_sent": sent_tail, "tail_pps": tail_pps, "tail_resets_per_second": per_second,
        "total_resets": len(resets),
    }))


if __name__ == "__main__":
    main()
