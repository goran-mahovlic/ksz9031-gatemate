#!/usr/bin/env python3
"""
decode_ila.py — decode UART-ILA hex dump from fpga_phase5.v.

Sample format (Phase 5):
    $XXXX\r\n   where XXXX is the 16-bit sample word in hex, MSB first.
    '$' is a sync character; 128 samples per MDIO trigger.

Probe bit mapping (fpga_phase5.v):
    [0]   mdio_pad    — raw MDIO pad (2-FF synced)
    [1]   mdio_out    — FPGA drive value
    [2]   mdio_oe     — 1=FPGA drives, 0=Hi-Z
    [3]   mdc         — MDC clock to PHY
    [4]   busy
    [5]   rvalid
    [6]   mdio_start
    [7]   phy_ready
    [11:8]  state[3:0]
    [15:12] bit_cnt[3:0]

Usage:
    cat dump.bin | ./decode_ila.py
    ./decode_ila.py < dump.bin
"""

import sys
import re

STATE_NAMES = {
    0x0: "IDLE",
    0x1: "PREA",
    0x2: "STRT",
    0x3: "OP  ",
    0x4: "PHYA",
    0x5: "REGA",
    0x6: "TA  ",
    0x7: "DATA",
    0x8: "DONE",
}

SAMPLE_PERIOD_NS = 200  # 50 MHz / 10 = 5 MHz → 200 ns per sample


def parse_samples(text):
    pat = re.compile(r"\$([0-9A-Fa-f]{4})")
    return [int(m.group(1), 16) for m in pat.finditer(text)]


def decode(s):
    return {
        "pad":     (s >> 0) & 1,
        "out":     (s >> 1) & 1,
        "oe":      (s >> 2) & 1,
        "mdc":     (s >> 3) & 1,
        "busy":    (s >> 4) & 1,
        "rvalid":  (s >> 5) & 1,
        "start":   (s >> 6) & 1,
        "phyrdy":  (s >> 7) & 1,
        "state":   (s >> 8) & 0xF,
        "bitcnt":  (s >> 12) & 0xF,
    }


def main():
    raw = sys.stdin.buffer.read().decode("ascii", errors="replace")
    samples = parse_samples(raw)
    print(f"# parsed {len(samples)} samples\n")

    # Header
    print(f"  {'t(µs)':>7} {'bit':>3} {'state':<5} "
          f"{'mdc':>3} {'oe':>2} {'out':>3} {'pad':>3} {'busy':>4} {'rvld':>4}  transition?")
    print("  " + "-" * 72)

    # Track transitions: only print a line when any of these change
    prev_key = None
    prev_t = -1
    frame_count = 0
    current_frame_bits = []

    for i, s in enumerate(samples):
        d = decode(s)
        t_us = i * SAMPLE_PERIOD_NS / 1000

        key = (d["state"], d["bitcnt"], d["mdc"], d["oe"], d["out"], d["pad"],
               d["busy"], d["rvalid"])
        if key == prev_key:
            continue

        st_name = STATE_NAMES.get(d["state"], f"S{d['state']:X}")
        transition = ""

        # Capture MDIO bit on MDC rising edge during DATA or other driven states
        if prev_key and prev_key[2] == 0 and d["mdc"] == 1:
            # mdc rising edge — sample mdio_pad
            label = f"[mdc↑ @ {st_name} bit {d['bitcnt']}: pad={d['pad']} oe={d['oe']}]"
            transition = label
            if d["state"] == 7:
                current_frame_bits.append(d["pad"])

        # Frame boundary: detect entering IDLE after DATA
        if prev_key and prev_key[0] == 7 and d["state"] == 8:
            # Entering DONE from DATA — frame complete
            if current_frame_bits:
                val = 0
                for b in current_frame_bits[:16]:
                    val = (val << 1) | b
                print(f"  -- decoded MDIO val = 0x{val:04X} ({len(current_frame_bits)} bits) --")
                current_frame_bits = []
                frame_count += 1

        print(f"  {t_us:>7.2f} {d['bitcnt']:>3X} {st_name:<5} "
              f"{d['mdc']:>3} {d['oe']:>2} {d['out']:>3} {d['pad']:>3} "
              f"{d['busy']:>4} {d['rvalid']:>4}  {transition}")
        prev_key = key
        prev_t = t_us


if __name__ == "__main__":
    main()
