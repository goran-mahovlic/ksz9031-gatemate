#!/usr/bin/env python3
"""Throughput test for gbe_top (run on a host with a gigabit path to the board, not the Pi).

burst : send one datagram to UDP 1235; gbe_rgmii puts its echo on the wire 1 + BURST_N times back to
        back at line rate. Count the copies that arrive, the time from the first to the last and
        report Mb/s (UDP payload and Ethernet line rate incl. preamble/FCS/IFG) and loss.
echo  : send numbered datagrams to UDP 1234 at a paced rate for --seconds, count the echoes
        (the echo path runs through the 25 MHz MAC/stack, ~200 Mb/s ceiling).

  gbe_throughput.py <fpga_ip> burst [--repeat 3] [--expect 50001] [--size 1472]
  gbe_throughput.py <fpga_ip> echo  [--mbps 100] [--seconds 2] [--size 1472]
"""
import argparse
import socket
import struct
import time

WIRE_EXTRA = 8 + 14 + 20 + 8 + 4 + 12   # preamble+SFD, Ethernet, IPv4, UDP, FCS, IFG


def sock(rcvbuf=64 << 20):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
    s.bind(("0.0.0.0", 0))
    return s


def burst(ip, size, expect, idle):
    s = sock()
    payload = (b"gbe-burst-%08x-" % int(time.time() * 1000)).ljust(size, b"\x5a")
    s.settimeout(2.0)
    t_send = time.perf_counter()
    s.sendto(payload, (ip, 1235))
    buf = bytearray(2048)
    n = good = 0
    t_first = t_last = None
    try:
        k = s.recv_into(buf)
        t_first = t_last = time.perf_counter()
        n = 1
        good = int(k == size and buf[:k] == payload)
        s.settimeout(idle)
        while True:
            k = s.recv_into(buf)
            t_last = time.perf_counter()
            n += 1
            good += int(k == size and buf[:32] == payload[:32])
    except socket.timeout:
        pass
    rcvbuf = s.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    s.close()
    if n < 2:
        return dict(received=n, good=good, expect=expect, mbps=0.0, line_mbps=0.0,
                    loss=1.0 - n / expect, first_ms=None, span_s=0.0, rcvbuf=rcvbuf)
    span = t_last - t_first
    # n datagrams arrive over (n - 1) inter-arrival periods
    mbps = (n - 1) * size * 8 / span / 1e6
    return dict(received=n, good=good, expect=expect, mbps=mbps,
                line_mbps=mbps * (size + WIRE_EXTRA) / size, loss=1.0 - n / expect,
                first_ms=(t_first - t_send) * 1e3, span_s=span, rcvbuf=rcvbuf)


def echo(ip, size, mbps, seconds):
    s = sock()
    s.setblocking(False)
    gap = size * 8 / (mbps * 1e6) if mbps > 0 else 0.0
    sent = recv = bad = 0
    seen = set()
    buf = bytearray(2048)
    t0 = time.perf_counter()
    t_next = t0
    end = t0 + seconds
    tail = end + 0.5

    def drain():
        nonlocal recv, bad
        while True:
            try:
                k = s.recv_into(buf)
            except BlockingIOError:
                return
            seq = struct.unpack_from("!I", buf, 0)[0]
            if k == size and seq not in seen:
                seen.add(seq)
                recv += 1
            else:
                bad += 1

    while True:
        now = time.perf_counter()
        if now >= tail:
            break
        if now < end and now >= t_next:
            msg = struct.pack("!I", sent) + b"\xa5" * (size - 4)
            try:
                s.sendto(msg, (ip, 1234))
                sent += 1
                t_next += gap
            except BlockingIOError:
                pass
        drain()
    s.close()
    dur = seconds
    return dict(sent=sent, received=recv, dup_or_bad=bad, offered_mbps=sent * size * 8 / dur / 1e6,
                echo_mbps=recv * size * 8 / dur / 1e6, loss=1.0 - recv / sent if sent else 1.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ip")
    ap.add_argument("mode", choices=["burst", "echo"])
    ap.add_argument("--size", type=int, default=1472)
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--expect", type=int, default=50001)
    ap.add_argument("--idle", type=float, default=0.5)
    ap.add_argument("--mbps", type=float, default=100.0)
    ap.add_argument("--seconds", type=float, default=2.0)
    a = ap.parse_args()
    if a.mode == "burst":
        for i in range(a.repeat):
            r = burst(a.ip, a.size, a.expect, a.idle)
            print("burst %d: received %d/%d (good %d), loss %.3f %%, %.1f Mb/s UDP payload, "
                  "%.1f Mb/s on the wire, span %.3f s, first after %s ms, rcvbuf %d"
                  % (i + 1, r["received"], r["expect"], r["good"], 100 * r["loss"], r["mbps"],
                     r["line_mbps"], r["span_s"],
                     "%.2f" % r["first_ms"] if r["first_ms"] is not None else "-", r["rcvbuf"]),
                  flush=True)
            time.sleep(1.0)
    else:
        r = echo(a.ip, a.size, a.mbps, a.seconds)
        print("echo %d B @ %.0f Mb/s offered (%.1f actual): sent %d, echoed %d, loss %.3f %%, "
              "echo throughput %.1f Mb/s, dup/bad %d"
              % (a.size, a.mbps, r["offered_mbps"], r["sent"], r["received"], 100 * r["loss"],
                 r["echo_mbps"], r["dup_or_bad"]), flush=True)


if __name__ == "__main__":
    main()
