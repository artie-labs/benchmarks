#!/usr/bin/env python3
"""Idle TCP connections with a socket at both ends, to check that long-lived idle connections (database replication,
for example) survive a takeover.

  idle.py serve <port>                      echo server: answers each line with the same line
  idle.py hold <host> <port> <count> <dir>  opens count connections, then waits. Each time a file named check-<k>
                                            appears in dir, sends a line on every connection, waits up to 10 s for the
                                            echoes and writes result-<k>.json: ok, reset, timeout, other
"""
import json, os, selectors, socket, sys, time


def serve(port):
    sel = selectors.DefaultSelector()
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("0.0.0.0", port))
    ls.listen(4096)
    ls.setblocking(False)
    sel.register(ls, selectors.EVENT_READ)
    while True:
        for key, _ in sel.select():
            s = key.fileobj
            if s is ls:
                c, _ = ls.accept()
                c.setblocking(False)
                sel.register(c, selectors.EVENT_READ)
                continue
            try:
                data = s.recv(4096)
            except OSError:
                data = b""
            if not data:
                sel.unregister(s)
                s.close()
                continue
            try:
                s.send(data)
            except OSError:
                pass


def check(conns):
    result = {"ok": 0, "reset": 0, "timeout": 0, "other": 0, "dead_before": 0}
    pending = {}
    for i, s in enumerate(conns):
        if s is None:
            result["dead_before"] += 1
            continue
        try:
            s.send(b"ping %d\n" % i)
            pending[s] = i
        except ConnectionResetError:
            result["reset"] += 1
            conns[i] = None
        except OSError:
            result["other"] += 1
            conns[i] = None
    deadline = time.time() + 10
    sel = selectors.DefaultSelector()
    for s in pending:
        sel.register(s, selectors.EVENT_READ)
    while pending and time.time() < deadline:
        for key, _ in sel.select(timeout=max(0, deadline - time.time())):
            s = key.fileobj
            i = pending.pop(s)
            sel.unregister(s)
            try:
                data = s.recv(4096)
                if data:
                    result["ok"] += 1
                else:
                    result["other"] += 1
                    conns[i] = None
            except ConnectionResetError:
                result["reset"] += 1
                conns[i] = None
            except OSError:
                result["other"] += 1
                conns[i] = None
    for s, i in pending.items():
        result["timeout"] += 1
        conns[i] = None
    return result


def hold(host, port, count, out):
    os.makedirs(out, exist_ok=True)
    conns = []
    for _ in range(count):
        s = socket.create_connection((host, port), timeout=10)
        s.setblocking(False)
        conns.append(s)
    with open(os.path.join(out, "opened"), "w") as f:
        f.write("%d %f\n" % (len(conns), time.time()))
    done = set()
    while True:
        for name in sorted(os.listdir(out)):
            if name.startswith("check-") and name not in done:
                done.add(name)
                r = check(conns)
                r["at"] = time.time()
                with open(os.path.join(out, "result-" + name[6:] + ".json"), "w") as f:
                    json.dump(r, f)
            if name == "stop":
                return
        time.sleep(0.2)


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(int(sys.argv[2]))
    else:
        hold(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
