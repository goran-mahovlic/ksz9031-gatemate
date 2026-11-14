#!/bin/bash
# End-to-end simulation of eth100_top at the RGMII pins (iverilog). Prints PASS / FAILED.
set -euo pipefail
OSS="${OSS_CAD_SUITE:-$HOME/Programs/oss-cad-suite}"
export PATH="$OSS/bin:$PATH"
D="$(cd "$(dirname "$0")" && pwd)"; P="$D/../.."
L="$P/lib/eth/rtl"; A="$P/lib/eth/lib/axis/rtl"; R="$P/rtl"
OUT="${OUT:-${TMPDIR:-/tmp}}/tb_eth100.vvp"
iverilog -g2012 -o "$OUT" -s tb_eth100 ${EXTRA_TOP:-} -Wno-timescale \
  "$D/tb_eth100.v" "$D/gm_models.v" ${EXTRA:-} \
  "$R/eth100_top.v" "$R/eth_core.v" "$R/icmp_echo.v" "$R/mdio_phy_init.v" "$R/uart_status.v" \
  "$R/gm_eth_mac_1g_fifo.v" "$R/gm_sync_fifo.v" "$R/gm_async_fifo.v" "$R/gm_ip_eth_rx.v" "$R/gm_arp.v" \
  "$R/lfsr_precomputed.v" \
  "$L/eth_mac_1g.v" "$L/axis_gmii_rx.v" "$L/axis_gmii_tx.v" "$L/eth_axis_rx.v" "$L/eth_axis_tx.v" \
  "$L/udp_complete.v" "$L/udp.v" "$L/udp_ip_rx.v" "$L/udp_ip_tx.v" "$L/udp_checksum_gen.v" \
  "$L/ip_complete.v" "$L/ip.v" "$L/ip_eth_tx.v" "$L/ip_arb_mux.v" "$L/arp_cache.v" "$L/arp_eth_rx.v" \
  "$L/arp_eth_tx.v" "$L/eth_arb_mux.v" "$A/axis_fifo.v" "$A/arbiter.v" "$A/priority_encoder.v"
vvp -n "$OUT" | tee "${LOG:-/dev/null}"
