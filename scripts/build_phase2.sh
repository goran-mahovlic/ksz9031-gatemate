#!/bin/bash
# PHASE 2 BUILD — minimal UART heartbeat design (no MAC/UDP/ARP)
# Purpose: prove PLL + reset + UART work before layering anything else.

set -e

# Toolchain location: override with OSS_CAD_SUITE=/path/to/oss-cad-suite
export PATH="${OSS_CAD_SUITE:-$HOME/Programs/oss-cad-suite}/bin:$PATH"

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJ_DIR/build_phase2"
RTL_DIR="$PROJ_DIR/rtl"
SDC="$PROJ_DIR/constraints/timing.sdc"
CCF="$PROJ_DIR/constraints/ulx5m_gs.ccf"

DEVICE="CCGM1A1"
TOP="fpga"
SEED=1

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "=== [1/3] Synthesis (Yosys) — Phase 2 heartbeat only ==="
yosys -l "$BUILD_DIR/synth.log" -p "
    read_verilog $RTL_DIR/fpga_phase2.v
    read_verilog $RTL_DIR/gatemate_25MHz_125MHz_pll.v
    read_verilog $RTL_DIR/reset_sync.v
    read_verilog $RTL_DIR/uart.v
    read_verilog $RTL_DIR/uart_heartbeat.v
    synth_gatemate -top $TOP -luttree -nomx8 -json $BUILD_DIR/$TOP.json
"

echo "=== [2/3] Place & Route (nextpnr-himbaechel) ==="
nextpnr-himbaechel \
    --device "$DEVICE" \
    --json "$BUILD_DIR/$TOP.json" \
    --vopt "ccf=$CCF" \
    --vopt "out=$BUILD_DIR/${TOP}.cfg" \
    --router default \
    --seed "$SEED" \
    --sdc "$SDC" \
    --timing-allow-fail \
    --vopt no-cpe-cp \
    2>&1 | tee "$BUILD_DIR/pnr.log"

echo "=== [3/3] Pack (gmpack) ==="
gmpack "$BUILD_DIR/$TOP.cfg" --bit "$BUILD_DIR/$TOP.bit"

echo ""
echo "=== PHASE 2 BUILD COMPLETE ==="
ls -la "$BUILD_DIR/$TOP.bit"
