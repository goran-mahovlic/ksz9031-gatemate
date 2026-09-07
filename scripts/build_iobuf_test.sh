#!/bin/bash
# Build manual IOBUF test design — minimal SET/GET tester for eth_mdio.
# Lets us prove (or disprove) whether GateMate silicon honors CC_IOBUF.T,
# independent of the MDIO FSM.
set -e

# Toolchain location: override with OSS_CAD_SUITE=/path/to/oss-cad-suite
export PATH="${OSS_CAD_SUITE:-$HOME/Programs/oss-cad-suite}/bin:$PATH"

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJ_DIR/build_iobuf_test"
RTL_DIR="$PROJ_DIR/rtl"
SDC="$PROJ_DIR/constraints/timing_phase5.sdc"
CCF="$PROJ_DIR/constraints/iobuf_test.ccf"

DEVICE="CCGM1A1"
TOP="fpga"
SEED="${SEED:-1}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "=== [1/3] Synthesis (Yosys) ==="
yosys -l "$BUILD_DIR/synth.log" -p "
    read_verilog $RTL_DIR/iobuf_test.v
    read_verilog $RTL_DIR/pll_50mhz.v
    read_verilog $RTL_DIR/uart.v
    synth_gatemate -top $TOP -luttree -nomx8 -json $BUILD_DIR/$TOP.json
" 2>&1 | tail -20

echo "=== [2/3] Place & Route ==="
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
    2>&1 | tee "$BUILD_DIR/pnr.log" | grep -E "Constraining|Max frequency|ERROR" | head -20

echo "=== [3/3] Pack ==="
gmpack "$BUILD_DIR/$TOP.cfg" --bit "$BUILD_DIR/$TOP.bit"

echo ""
echo "=== IOBUF TEST BUILD COMPLETE ==="
ls -la "$BUILD_DIR/$TOP.bit"
