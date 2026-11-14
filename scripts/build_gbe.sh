#!/bin/bash
# Build the 1000 Mb/s Ethernet design (top gbe_top) for ULX5M-GS (CCGM1A1).
# Toolchain: oss-cad-suite-20261016 (yosys 0.70+145, nextpnr-himbaechel 0.11.1-63, gmpack v1.13-6).
#   OSS_CAD_SUITE=/path/to/oss-cad-suite   toolchain root (default ~/Programs/oss-cad-suite)
#   SEED=<n>                               nextpnr seed (default 1)
#   OUT=<dir>                              output directory (default build_eth100)
set -euo pipefail

OSS="${OSS_CAD_SUITE:-$HOME/Programs/oss-cad-suite}"
export PATH="$OSS/bin:$PATH"

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$PROJ_DIR/build_gbe}"
SEED="${SEED:-1}"
RTL="$PROJ_DIR/rtl"
LIB="$PROJ_DIR/lib/eth/rtl"
AXIS="$PROJ_DIR/lib/eth/lib/axis/rtl"
CCF="$PROJ_DIR/constraints/ulx5m_gs_gbe.ccf"
SDC="$PROJ_DIR/constraints/timing_gbe.sdc"
TOP=gbe_top

mkdir -p "$OUT"

SRCS=(
  "$RTL/gbe_top.v" "$RTL/gbe_rgmii.v" "$RTL/eth_core.v" "$RTL/icmp_echo.v" "$RTL/mdio_phy_init.v" "$RTL/uart_status.v"
  "$RTL/gm_eth_mac_1g_fifo.v" "$RTL/gm_sync_fifo.v" "$RTL/gm_async_fifo.v"
  "$RTL/gm_ip_eth_rx.v" "$RTL/gm_arp.v" "$RTL/lfsr_precomputed.v"
  "$LIB/eth_mac_1g.v" "$LIB/axis_gmii_rx.v" "$LIB/axis_gmii_tx.v"
  "$LIB/eth_axis_rx.v" "$LIB/eth_axis_tx.v"
  "$LIB/udp_complete.v" "$LIB/udp.v" "$LIB/udp_ip_rx.v" "$LIB/udp_ip_tx.v"
  "$LIB/udp_checksum_gen.v" "$LIB/ip_complete.v" "$LIB/ip.v" "$LIB/ip_eth_tx.v"
  "$LIB/ip_arb_mux.v" "$LIB/arp_cache.v" "$LIB/arp_eth_rx.v" "$LIB/arp_eth_tx.v" "$LIB/eth_arb_mux.v"
  "$AXIS/axis_fifo.v" "$AXIS/arbiter.v" "$AXIS/priority_encoder.v"
)

if [ -n "${JSON:-}" ]; then
  echo "=== [1/3] yosys skipped, netlist $JSON"
  cp "$JSON" "$OUT/$TOP.json"
else
  echo "=== [1/3] yosys ($(yosys -V))"
  READS=""
  for f in "${SRCS[@]}"; do READS="$READS read_verilog -defer $f;"; done
  yosys -q -l "$OUT/synth.log" -p "$READS hierarchy -top $TOP; synth_gatemate -top $TOP -luttree -nomx8 -json $OUT/$TOP.json"
fi

echo "=== [2/3] nextpnr-himbaechel seed $SEED"
nextpnr-himbaechel --device CCGM1A1 --json "$OUT/$TOP.json" \
  --vopt ccf="$CCF" --sdc "$SDC" --vopt out="$OUT/$TOP.txt" \
  --router router2 --seed "$SEED" --timing-allow-fail \
  > "$OUT/pnr.log" 2>&1 || { tail -30 "$OUT/pnr.log"; exit 1; }

echo "=== [3/3] gmpack --reset (CMD_CFGRST: without it -r loads over the previous design)"
gmpack --reset "$OUT/$TOP.txt" "$OUT/$TOP.bit"

grep -E "Max frequency|Info: +(CPE_|RAM_|GLB|PLL|IOSEL|BUFG)" "$OUT/pnr.log" | sed 's/^Info: */  /' || true
echo "hold violations: $(grep -c 'Hold/min time violation for' "$OUT/pnr.log" || true)"
sha256sum "$OUT/$TOP.bit"
