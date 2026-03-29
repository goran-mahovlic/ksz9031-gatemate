#!/usr/bin/env python3
"""
MDIO over UART — Read/Write KSZ9031 PHY registers via FPGA UART interface.

Usage:
  python3 mdio_uart.py read  [phy] [reg]        # Read register
  python3 mdio_uart.py write [phy] [reg] [val]   # Write register
  python3 mdio_uart.py scan                       # Scan all PHY addresses
  python3 mdio_uart.py status                     # Read common status registers

Examples:
  python3 mdio_uart.py read 7 1          # Read PHY 7, reg 1 (Basic Status)
  python3 mdio_uart.py write 7 0 0x1200  # Write PHY 7, reg 0 (restart auto-neg)
  python3 mdio_uart.py status            # Quick PHY status overview
  python3 mdio_uart.py scan              # Find PHY address

Serial port: set SERIAL_PORT env var or defaults to /dev/ttyUSB0
"""

import serial
import sys
import os
import time

SERIAL_PORT = os.environ.get("SERIAL_PORT", "/dev/ttyUSB0")
BAUD_RATE = 115200
TIMEOUT = 0.5

# KSZ9031 register names
REG_NAMES = {
    0: "Basic Control",
    1: "Basic Status",
    2: "PHY ID 1",
    3: "PHY ID 2",
    4: "Auto-Neg Advertisement",
    5: "Auto-Neg Link Partner",
    6: "Auto-Neg Expansion",
    7: "Auto-Neg Next Page TX",
    8: "Auto-Neg Next Page RX",
    9: "1000BASE-T Control",
    10: "1000BASE-T Status",
    15: "Extended Status",
    31: "PHY Control",
}


def mdio_read(ser, phy, reg):
    ser.reset_input_buffer()
    cmd = bytes([ord('r'), 0x20 | (phy & 0x1F), 0x80 | (reg & 0x1F), ord('s')])
    ser.write(cmd)
    time.sleep(0.15)
    data = ser.read(2)
    if len(data) == 2:
        return (data[0] << 8) | data[1]
    return None


def mdio_write(ser, phy, reg, val):
    ser.reset_input_buffer()
    msb = (val >> 8) & 0xFF
    lsb = val & 0xFF
    cmd = bytes([ord('w'), 0x20 | (phy & 0x1F), 0x80 | (reg & 0x1F),
                 ord('d'), msb, lsb, ord('s')])
    ser.write(cmd)
    time.sleep(0.15)


def decode_bsr(val):
    """Decode Basic Status Register (reg 1)"""
    flags = []
    if val & 0x0004: flags.append("Link UP")
    else: flags.append("Link DOWN")
    if val & 0x0020: flags.append("Auto-neg Complete")
    if val & 0x0001: flags.append("Extended Cap")
    if val & 0x0008: flags.append("Remote Fault")
    if val & 0x0100: flags.append("100BASE-TX FD")
    if val & 0x2000: flags.append("100BASE-T4")
    if val & 0x0040: flags.append("MF Preamble")
    return ", ".join(flags) if flags else "none"


def decode_bcr(val):
    """Decode Basic Control Register (reg 0)"""
    flags = []
    if val & 0x8000: flags.append("Reset")
    if val & 0x4000: flags.append("Loopback")
    if val & 0x1000: flags.append("Auto-neg Enable")
    if val & 0x0200: flags.append("Restart Auto-neg")
    if val & 0x0100: flags.append("Duplex Full")
    speed = ((val >> 6) & 0x02) | ((val >> 13) & 0x01)
    speeds = {0: "10M", 1: "100M", 2: "1000M", 3: "Reserved"}
    flags.append(f"Speed={speeds.get(speed, '?')}")
    return ", ".join(flags)


def cmd_read(args):
    phy = int(args[0]) if len(args) > 0 else 7
    reg = int(args[1]) if len(args) > 1 else 1
    with serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=TIMEOUT) as ser:
        val = mdio_read(ser, phy, reg)
        if val is not None:
            name = REG_NAMES.get(reg, f"Register {reg}")
            print(f"PHY {phy}, Reg {reg} ({name}): 0x{val:04X} ({val})")
            if reg == 0: print(f"  → {decode_bcr(val)}")
            if reg == 1: print(f"  → {decode_bsr(val)}")
        else:
            print(f"No response from PHY {phy} reg {reg} — check UART connection and FPGA clock")


def cmd_write(args):
    if len(args) < 3:
        print("Usage: mdio_uart.py write <phy> <reg> <value>")
        return
    phy = int(args[0])
    reg = int(args[1])
    val = int(args[2], 0)
    with serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=TIMEOUT) as ser:
        mdio_write(ser, phy, reg, val)
        print(f"Wrote 0x{val:04X} to PHY {phy}, Reg {reg}")
        time.sleep(0.1)
        readback = mdio_read(ser, phy, reg)
        if readback is not None:
            print(f"Readback: 0x{readback:04X}")
        else:
            print("Readback failed")


def cmd_scan(args):
    print(f"Scanning PHY addresses 0-31 on {SERIAL_PORT}...")
    with serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=TIMEOUT) as ser:
        found = False
        for phy in range(32):
            val = mdio_read(ser, phy, 2)  # PHY ID 1
            if val is not None and val != 0xFFFF and val != 0x0000:
                val2 = mdio_read(ser, phy, 3)  # PHY ID 2
                print(f"  PHY {phy}: ID = 0x{val:04X}:0x{val2:04X if val2 else 0:04X}")
                found = True
        if not found:
            print("  No PHY found — FPGA may not be running correctly")


def cmd_status(args):
    phy = int(args[0]) if len(args) > 0 else 7
    print(f"PHY {phy} Status ({SERIAL_PORT}):")
    print("-" * 50)
    with serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=TIMEOUT) as ser:
        for reg in [0, 1, 2, 3, 4, 5, 9, 10]:
            val = mdio_read(ser, phy, reg)
            name = REG_NAMES.get(reg, f"Reg {reg}")
            if val is not None:
                line = f"  Reg {reg:2d} ({name:25s}): 0x{val:04X}"
                if reg == 0: line += f"  [{decode_bcr(val)}]"
                if reg == 1: line += f"  [{decode_bsr(val)}]"
                print(line)
            else:
                print(f"  Reg {reg:2d} ({name:25s}): NO RESPONSE")
                return


COMMANDS = {
    "read": cmd_read,
    "write": cmd_write,
    "scan": cmd_scan,
    "status": cmd_status,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1]
    if cmd not in COMMANDS:
        print(f"Unknown command: {cmd}")
        print(f"Available: {', '.join(COMMANDS.keys())}")
        sys.exit(1)

    COMMANDS[cmd](sys.argv[2:])
