#!/bin/bash
# PHASE 3 BUILD — MDIO diagnostic with UART trace (no MAC/UDP/ARP)
# Purpose: drive MDIO to KSZ9031 and print human-readable trace over UART.

set -e

export PATH=/home/klaudio/Programs/oss-cad-suite/bin:$PATH

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJ_DIR/build_phase4"
RTL_DIR="$PROJ_DIR/rtl"
SDC="$PROJ_DIR/constraints/timing_phase3.sdc"
CCF="$PROJ_DIR/constraints/ulx5m_gs.ccf"

DEVICE="CCGM1A1"
TOP="fpga"
SEED=1

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "=== [1/3] Synthesis (Yosys) — Phase 3 MDIO+UART trace ==="
yosys -l "$BUILD_DIR/synth.log" -p "
    read_verilog $RTL_DIR/fpga_phase4.v
    
    read_verilog $RTL_DIR/uart.v
    read_verilog $RTL_DIR/mdio_controller.v
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
echo "=== PHASE 3 BUILD COMPLETE ==="
ls -la "$BUILD_DIR/$TOP.bit"
echo ""
grep -E "Max frequency" "$BUILD_DIR/pnr.log" || true
