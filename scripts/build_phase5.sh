#!/bin/bash
# PHASE 5 BUILD — UART-ILA for MDIO debug
# Captures MDIO/MDC/FSM state on every transaction and dumps via UART.

set -e

# Toolchain location: override with OSS_CAD_SUITE=/path/to/oss-cad-suite
export PATH="${OSS_CAD_SUITE:-$HOME/Programs/oss-cad-suite}/bin:$PATH"

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJ_DIR/build_phase5"
RTL_DIR="$PROJ_DIR/rtl"
SDC="$PROJ_DIR/constraints/timing_phase5.sdc"
CCF="$PROJ_DIR/constraints/ulx5m_gs.ccf"

DEVICE="CCGM1A1"
TOP="fpga"
SEED="${SEED:-1}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "=== [1/3] Synthesis (Yosys) — Phase 5 UART-ILA ==="
yosys -l "$BUILD_DIR/synth.log" -p "
    read_verilog $RTL_DIR/fpga_phase5.v
    read_verilog $RTL_DIR/pll_50mhz.v
    read_verilog $RTL_DIR/uart.v
    read_verilog $RTL_DIR/uart_ila.v
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
echo "=== PHASE 5 BUILD COMPLETE ==="
ls -la "$BUILD_DIR/$TOP.bit"
echo ""
grep -E "Max frequency" "$BUILD_DIR/pnr.log" || true
