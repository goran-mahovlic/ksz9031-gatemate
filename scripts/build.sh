#!/bin/bash
# Build script for KSZ9031 GbE on GateMate CCGM1A1 (ULX5M-GS)
# Toolchain: Yosys → nextpnr-himbaechel → gmpack

set -e

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJ_DIR/build"
RTL_DIR="$PROJ_DIR/rtl"
LIB_DIR="$PROJ_DIR/lib/eth/rtl"
AXIS_DIR="$PROJ_DIR/lib/eth/lib/axis/rtl"
CCF="$PROJ_DIR/constraints/ulx5m_gs.ccf"
SDC="$PROJ_DIR/constraints/timing.sdc"

DEVICE="CCGM1A1"
TOP="fpga"
SEED=256

mkdir -p "$BUILD_DIR"

echo "=== [1/3] Synthesis (Yosys) ==="
yosys -l "$BUILD_DIR/synth.log" -p "
    read_verilog $RTL_DIR/fpga.v
    read_verilog $RTL_DIR/fpga_core.v
    read_verilog $RTL_DIR/gatemate_rgmii_if.v
    read_verilog $RTL_DIR/uart.v
    read_verilog $RTL_DIR/sync_signal.v
    read_verilog $RTL_DIR/debounce_switch.v
    read_verilog $RTL_DIR/mdio_controller.v
    read_verilog $RTL_DIR/mdio_init.v
    read_verilog $RTL_DIR/gm_sync_fifo.v
    read_verilog $RTL_DIR/gm_async_fifo.v
    read_verilog $RTL_DIR/gm_eth_mac_1g_fifo.v
    read_verilog $LIB_DIR/eth_mac_1g.v
    read_verilog $LIB_DIR/axis_gmii_rx.v
    read_verilog $LIB_DIR/axis_gmii_tx.v
    read_verilog $AXIS_DIR/axis_fifo.v
    read_verilog $LIB_DIR/eth_axis_rx.v
    read_verilog $LIB_DIR/eth_axis_tx.v
    read_verilog $LIB_DIR/udp_complete.v
    read_verilog $LIB_DIR/udp.v
    read_verilog $LIB_DIR/udp_ip_rx.v
    read_verilog $LIB_DIR/udp_ip_tx.v
    read_verilog $LIB_DIR/udp_checksum_gen.v
    read_verilog $LIB_DIR/udp_mux.v
    read_verilog $LIB_DIR/udp_demux.v
    read_verilog $LIB_DIR/ip_complete.v
    read_verilog $LIB_DIR/ip.v
    read_verilog $RTL_DIR/gm_ip_eth_rx.v
    read_verilog $LIB_DIR/ip_eth_tx.v
    read_verilog $LIB_DIR/ip_arb_mux.v
    read_verilog $LIB_DIR/ip_mux.v
    read_verilog $LIB_DIR/ip_demux.v
    read_verilog $RTL_DIR/gm_arp.v
    read_verilog $LIB_DIR/arp_cache.v
    read_verilog $LIB_DIR/arp_eth_rx.v
    read_verilog $LIB_DIR/arp_eth_tx.v
    read_verilog $LIB_DIR/eth_arb_mux.v
    read_verilog $LIB_DIR/eth_mux.v
    read_verilog $LIB_DIR/eth_demux.v
    read_verilog $RTL_DIR/lfsr_precomputed.v
    read_verilog $AXIS_DIR/arbiter.v
    read_verilog $AXIS_DIR/priority_encoder.v
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
    --placer-heap-cell-placement-timeout 20000 \
    --timing-allow-fail \
    2>&1 | tee "$BUILD_DIR/pnr.log"

echo "=== [3/3] Pack (gmpack) ==="
gmpack "$BUILD_DIR/$TOP.cfg" --bit "$BUILD_DIR/$TOP.bit"

echo ""
echo "=== BUILD COMPLETE ==="
echo "Bitstream: $BUILD_DIR/$TOP.bit"
ls -la "$BUILD_DIR/$TOP.bit"
