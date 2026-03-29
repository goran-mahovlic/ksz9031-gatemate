#!/usr/bin/env python3
"""
Precompute lfsr_mask() for all configurations used in this design.
Generates rtl/lfsr_precomputed.v — a drop-in replacement for lib/eth/rtl/lfsr.v
that uses hardcoded XOR logic instead of slow Verilog function evaluation.

Configurations needed:
  1. axis_gmii_rx.v / axis_gmii_tx.v:
     LFSR_WIDTH=32, POLY=0x4c11db7, GALOIS, FEED_FORWARD=0, REVERSE=1, DATA_WIDTH=8
  2. arp_cache.v (×2):
     LFSR_WIDTH=32, POLY=0x4c11db7, GALOIS, FEED_FORWARD=0, REVERSE=1, DATA_WIDTH=32
  3. udp_checksum_gen.v:
     LFSR_WIDTH=16, POLY=0x8005, FIBONACCI, FEED_FORWARD=0, REVERSE=0, DATA_WIDTH=8
     (needs checking — see below)

Usage:
  python3 scripts/precompute_lfsr.py
  # Generates rtl/lfsr_precomputed.v
"""

import sys
import os


def compute_masks(lfsr_width, lfsr_poly, lfsr_config, lfsr_feed_forward, reverse, data_width):
    """
    Python translation of lfsr_mask() Verilog function.
    Returns list of (LFSR_WIDTH+DATA_WIDTH)-bit integers, one per output bit.
    Index 0..LFSR_WIDTH-1 = state_out bits
    Index LFSR_WIDTH..LFSR_WIDTH+DATA_WIDTH-1 = data_out bits
    """
    # State tracking: lfsr_mask_state[i] = integer bitmask over state_in inputs
    #                 lfsr_mask_data[i]  = integer bitmask over data_in inputs
    lfsr_mask_state = [0] * lfsr_width
    lfsr_mask_data  = [0] * lfsr_width
    output_mask_state = [0] * data_width
    output_mask_data  = [0] * data_width

    # Init: bit i of state_in → position i (identity)
    for i in range(lfsr_width):
        lfsr_mask_state[i] = (1 << i)
        lfsr_mask_data[i]  = 0

    # Init output masks
    for i in range(data_width):
        output_mask_state[i] = (1 << i) if i < lfsr_width else 0
        output_mask_data[i]  = 0

    if lfsr_config == "GALOIS":
        # data_mask iterates MSB first: bit (data_width-1) down to bit 0
        for bit_idx in range(data_width):
            input_bit = data_width - 1 - bit_idx  # which data_in bit this is

            state_val = lfsr_mask_state[lfsr_width - 1]
            data_val  = lfsr_mask_data[lfsr_width - 1]
            data_val ^= (1 << input_bit)  # XOR with this input bit

            # Shift output registers
            for j in range(data_width - 1, 0, -1):
                output_mask_state[j] = output_mask_state[j - 1]
                output_mask_data[j]  = output_mask_data[j - 1]
            output_mask_state[0] = state_val
            output_mask_data[0]  = data_val

            if lfsr_feed_forward:
                state_val = 0
                data_val  = (1 << input_bit)

            # Shift LFSR register
            for j in range(lfsr_width - 1, 0, -1):
                lfsr_mask_state[j] = lfsr_mask_state[j - 1]
                lfsr_mask_data[j]  = lfsr_mask_data[j - 1]
            lfsr_mask_state[0] = state_val
            lfsr_mask_data[0]  = data_val

            # XOR polynomial bits
            for j in range(1, lfsr_width):
                if (lfsr_poly >> j) & 1:
                    lfsr_mask_state[j] ^= state_val
                    lfsr_mask_data[j]  ^= data_val

    elif lfsr_config == "FIBONACCI":
        for bit_idx in range(data_width):
            input_bit = data_width - 1 - bit_idx

            state_val = lfsr_mask_state[lfsr_width - 1]
            data_val  = lfsr_mask_data[lfsr_width - 1]
            data_val ^= (1 << input_bit)

            # XOR from poly positions before shifting
            for j in range(1, lfsr_width):
                if (lfsr_poly >> j) & 1:
                    state_val ^= lfsr_mask_state[j - 1]
                    data_val  ^= lfsr_mask_data[j - 1]

            # Shift output registers
            for j in range(data_width - 1, 0, -1):
                output_mask_state[j] = output_mask_state[j - 1]
                output_mask_data[j]  = output_mask_data[j - 1]
            output_mask_state[0] = state_val
            output_mask_data[0]  = data_val

            if lfsr_feed_forward:
                state_val = 0
                data_val  = (1 << input_bit)

            # Shift LFSR
            for j in range(lfsr_width - 1, 0, -1):
                lfsr_mask_state[j] = lfsr_mask_state[j - 1]
                lfsr_mask_data[j]  = lfsr_mask_data[j - 1]
            lfsr_mask_state[0] = state_val
            lfsr_mask_data[0]  = data_val
    else:
        raise ValueError(f"Unknown LFSR config: {lfsr_config}")

    def bit_reverse(val, width):
        result = 0
        for i in range(width):
            if (val >> i) & 1:
                result |= 1 << (width - 1 - i)
        return result

    masks = []
    if reverse:
        # state_out[n] uses lfsr_mask_state[lfsr_width-n-1] bit-reversed
        for n in range(lfsr_width):
            s = bit_reverse(lfsr_mask_state[lfsr_width - n - 1], lfsr_width)
            d = bit_reverse(lfsr_mask_data[lfsr_width - n - 1], data_width)
            masks.append((d << lfsr_width) | s)
        # data_out[n] uses output_mask_state[data_width-n-1] bit-reversed
        for n in range(data_width):
            s = bit_reverse(output_mask_state[data_width - n - 1], lfsr_width)
            d = bit_reverse(output_mask_data[data_width - n - 1], data_width)
            masks.append((d << lfsr_width) | s)
    else:
        for n in range(lfsr_width):
            masks.append((lfsr_mask_data[n] << lfsr_width) | lfsr_mask_state[n])
        for n in range(data_width):
            masks.append((output_mask_data[n] << lfsr_width) | output_mask_state[n])

    return masks


def generate_xor_assign(output_bit, mask, lfsr_width, data_width, total_width):
    """Generate 'assign out[n] = state_in[x] ^ state_in[y] ^ ... ^ data_in[z] ^ ...;'"""
    terms = []
    for i in range(lfsr_width):
        if (mask >> i) & 1:
            terms.append(f"state_in[{i}]")
    for i in range(data_width):
        if (mask >> (lfsr_width + i)) & 1:
            terms.append(f"data_in[{i}]")
    if not terms:
        return f"    assign state_out[{output_bit}] = 1'b0;" if output_bit < lfsr_width else f"    assign data_out[{output_bit - lfsr_width}] = 1'b0;"
    xor_str = " ^ ".join(terms)
    if output_bit < lfsr_width:
        return f"    assign state_out[{output_bit}] = {xor_str};"
    else:
        return f"    assign data_out[{output_bit - lfsr_width}] = {xor_str};"


def generate_case_body(lfsr_width, lfsr_poly, lfsr_config, lfsr_feed_forward, reverse, data_width):
    """Generate the assign statements for one parameter combination."""
    masks = compute_masks(lfsr_width, lfsr_poly, lfsr_config, lfsr_feed_forward, reverse, data_width)
    lines = []
    total = lfsr_width + data_width
    for n in range(lfsr_width):
        lines.append(generate_xor_assign(n, masks[n], lfsr_width, data_width, total))
    for n in range(data_width):
        lines.append(generate_xor_assign(lfsr_width + n, masks[lfsr_width + n], lfsr_width, data_width, total))
    return lines


def generate_verilog(configs):
    """
    configs: list of dicts with keys:
      lfsr_width, lfsr_poly, lfsr_config, lfsr_feed_forward, reverse, data_width
    Returns the Verilog string.
    """
    lines = []
    lines.append("/*")
    lines.append(" * AUTO-GENERATED by scripts/precompute_lfsr.py")
    lines.append(" * Drop-in replacement for lib/eth/rtl/lfsr.v")
    lines.append(" * Uses precomputed XOR trees instead of slow Verilog function evaluation.")
    lines.append(" * This file is used in build.sh INSTEAD of lib/eth/rtl/lfsr.v")
    lines.append(" */")
    lines.append("")
    lines.append("`resetall")
    lines.append("`timescale 1ns / 1ps")
    lines.append("`default_nettype none")
    lines.append("")
    lines.append("module lfsr #")
    lines.append("(")
    lines.append("    parameter LFSR_WIDTH = 31,")
    lines.append("    parameter LFSR_POLY = 31'h10000001,")
    lines.append("    parameter LFSR_CONFIG = \"FIBONACCI\",")
    lines.append("    parameter LFSR_FEED_FORWARD = 0,")
    lines.append("    parameter REVERSE = 0,")
    lines.append("    parameter DATA_WIDTH = 8,")
    lines.append("    parameter STYLE = \"AUTO\"")
    lines.append(")")
    lines.append("(")
    lines.append("    input  wire [DATA_WIDTH-1:0] data_in,")
    lines.append("    input  wire [LFSR_WIDTH-1:0] state_in,")
    lines.append("    output wire [DATA_WIDTH-1:0] data_out,")
    lines.append("    output wire [LFSR_WIDTH-1:0] state_out")
    lines.append(");")
    lines.append("")
    lines.append("generate")
    lines.append("")

    first = True
    for cfg in configs:
        lw  = cfg['lfsr_width']
        lp  = cfg['lfsr_poly']
        lc  = cfg['lfsr_config']
        lff = cfg['lfsr_feed_forward']
        rev = cfg['reverse']
        dw  = cfg['data_width']

        # Build parameter check condition
        cond_parts = [
            f"LFSR_WIDTH == {lw}",
            f"LFSR_POLY == {lw}'h{lp:x}",
            f"LFSR_CONFIG == \"{lc}\"",
            f"LFSR_FEED_FORWARD == {lff}",
            f"REVERSE == {1 if rev else 0}",
            f"DATA_WIDTH == {dw}",
        ]
        cond = " && ".join(cond_parts)

        if first:
            lines.append(f"if ({cond}) begin : precomputed_{lw}_{dw}")
            first = False
        else:
            lines.append(f"end else if ({cond}) begin : precomputed_{lw}_{dw}")

        lines.append(f"    // LFSR_WIDTH={lw}, DATA_WIDTH={dw}, {lc}, POLY=0x{lp:x}, REV={rev}")
        body = generate_case_body(lw, lp, lc, lff, rev, dw)
        lines.extend(body)
        lines.append("")

    # Fallback: error for unsupported configurations
    lines.append("end else begin : unsupported")
    lines.append("    // Unsupported configuration — outputs forced to zero.")
    lines.append("    // Add the required configuration to scripts/precompute_lfsr.py and regenerate.")
    lines.append("    assign state_out = {LFSR_WIDTH{1'b0}};")
    lines.append("    assign data_out  = {DATA_WIDTH{1'b0}};")
    lines.append("")
    lines.append("end")
    lines.append("")
    lines.append("endgenerate")
    lines.append("")
    lines.append("endmodule")
    lines.append("")
    lines.append("`resetall")
    lines.append("")

    return "\n".join(lines)


# ============================================================
# Configurations used in this design
# ============================================================
CONFIGS = [
    # axis_gmii_rx.v and axis_gmii_tx.v
    {
        'lfsr_width':       32,
        'lfsr_poly':        0x4c11db7,
        'lfsr_config':      "GALOIS",
        'lfsr_feed_forward': 0,
        'reverse':          True,
        'data_width':       8,
    },
    # arp_cache.v (two instances, same params)
    {
        'lfsr_width':       32,
        'lfsr_poly':        0x4c11db7,
        'lfsr_config':      "GALOIS",
        'lfsr_feed_forward': 0,
        'reverse':          True,
        'data_width':       32,
    },
]


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    proj_dir   = os.path.dirname(script_dir)
    out_path   = os.path.join(proj_dir, "rtl", "lfsr_precomputed.v")

    print(f"Computing masks for {len(CONFIGS)} configurations...")
    for cfg in CONFIGS:
        print(f"  LFSR_WIDTH={cfg['lfsr_width']}, DATA_WIDTH={cfg['data_width']}, "
              f"{cfg['lfsr_config']}, POLY=0x{cfg['lfsr_poly']:x}, "
              f"REV={cfg['reverse']}, FF={cfg['lfsr_feed_forward']}")
        masks = compute_masks(**cfg)
        print(f"    → {len(masks)} masks computed OK")

    verilog = generate_verilog(CONFIGS)

    with open(out_path, "w") as f:
        f.write(verilog)

    print(f"\nGenerated: {out_path}")
    print(f"Lines: {verilog.count(chr(10))}")
    print("\nDone. Update build.sh to use rtl/lfsr_precomputed.v instead of lib/eth/rtl/lfsr.v")
