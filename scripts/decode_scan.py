#!/usr/bin/env python3
"""
decode_scan.py — decode UART-ILA captures into per-PHY-address results.

For each capture of 128 samples:
  - Extract the PHYAD bits sent by the FPGA (from S_PHYAD state, MDC rising edges)
  - Extract the REGAD bits sent
  - Extract the 16-bit DATA returned by the PHY (from S_DATA state, MDC rising edges)
  - Report: PHYAD reg=X -> val=Y, plus whether PHY ACK'd (TA bit 1 = 0)
"""

import sys
import re
from collections import defaultdict

STATE = {0: "IDLE", 1: "PREA", 2: "STRT", 3: "OP", 4: "PHYA",
         5: "REGA", 6: "TA", 7: "DATA", 8: "DONE"}


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


def split_captures(samples, size=128):
    """
    Phase 5 re-arms ILA on each mdio_start. We can't easily detect
    capture boundaries from content — so we chunk every 128 samples.
    """
    return [samples[i:i+size] for i in range(0, len(samples), size)]


def process_capture(samples, idx):
    """Extract PHYAD/REGAD/DATA from the MDC rising edges in this capture."""
    prev = None
    # Per-state collected bits (captured on MDC rising edges)
    bits = defaultdict(list)
    prev_mdc = None
    for d_raw in samples:
        d = decode(d_raw)
        if prev_mdc == 0 and d["mdc"] == 1:
            # MDC rising edge — sample bit
            # Use oe/out/pad as appropriate
            if d["state"] in (4, 5):  # PHYAD or REGAD — FPGA drives, use `out`
                bits[STATE[d["state"]]].append(d["out"])
            elif d["state"] == 7:  # DATA — PHY drives, use `pad`
                bits[STATE[d["state"]]].append(d["pad"])
            elif d["state"] == 6:  # TA — mixed, record pad
                bits[STATE[d["state"]]].append(d["pad"])
        prev_mdc = d["mdc"]

    def bits_to_int(blist):
        v = 0
        for b in blist:
            v = (v << 1) | b
        return v

    phyad_bits = bits["PHYA"][:5]
    regad_bits = bits["REGA"][:5]
    ta_bits    = bits["TA"][:2]
    data_bits  = bits["DATA"][:16]

    phyad = bits_to_int(phyad_bits) if phyad_bits else None
    regad = bits_to_int(regad_bits) if regad_bits else None
    data  = bits_to_int(data_bits) if data_bits else None

    # PHY ACK: TA bit 1 should be 0 if PHY drives response
    ack = None
    if len(ta_bits) >= 2:
        ack = (ta_bits[1] == 0)

    return {
        "idx": idx,
        "phyad": phyad, "phyad_bits": len(phyad_bits),
        "regad": regad, "regad_bits": len(regad_bits),
        "data": data, "data_bits": len(data_bits),
        "ack": ack,
    }


def main():
    raw = sys.stdin.buffer.read().decode("ascii", errors="replace")
    samples = parse_samples(raw)
    captures = split_captures(samples, 128)

    print(f"# parsed {len(samples)} samples → {len(captures)} captures\n")
    print(f"  {'cap':>4} {'phyad':>5} {'reg':>3} {'ack':>3} {'val(hex)':>8}  note")
    print("  " + "-" * 50)

    summary = {}
    for i, cap in enumerate(captures):
        if len(cap) < 60:
            continue
        r = process_capture(cap, i)
        phyad_str = f"{r['phyad']:02X}" if r['phyad'] is not None else "??"
        reg_str = f"{r['regad']:02X}" if r['regad'] is not None else "??"
        ack_str = "Y" if r['ack'] else ("n" if r['ack'] is False else "?")
        val_str = f"0x{r['data']:04X}" if r['data'] is not None else "    ????"

        note = []
        if r['ack'] is False:
            note.append("no PHY response")
        if r['data'] == 0x0022:
            note.append("** KSZ9031 PHY ID1 MATCH **")
        if r['data'] and r['data'] != 0x0000 and r['data'] != 0xFFFF:
            note.append("non-zero!")

        print(f"  {i:>4} {phyad_str:>5} {reg_str:>3} {ack_str:>3} {val_str:>8}  {' '.join(note)}")
        if r['phyad'] is not None:
            summary[r['phyad']] = r['data']

    print()
    print("  Per-PHYAD summary:")
    for addr in sorted(summary.keys()):
        v = summary[addr]
        v_str = f"0x{v:04X}" if v is not None else "????"
        note = " <-- NON-ZERO" if v not in (0x0000, 0xFFFF, None) else ""
        print(f"    PHY {addr:02X}: val={v_str}{note}")


if __name__ == "__main__":
    main()
