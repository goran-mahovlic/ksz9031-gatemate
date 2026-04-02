#!/bin/bash
# Seed Search — traži seed s najboljim timing rezultatom za GateMate ETH
# Koristi custom nextpnr-himbaechel binary
# Usage: bash seed_search.sh [start_seed] [end_seed]
#   Default: seeds 1..200

set -e

PROJ_DIR="${PROJ_DIR:-$HOME/projects/ksz9031-gatemate}"
BUILD_DIR="$PROJ_DIR/build"
RTL_DIR="$PROJ_DIR/rtl"
LIB_DIR="$PROJ_DIR/lib/eth/rtl"
AXIS_DIR="$PROJ_DIR/lib/eth/lib/axis/rtl"
CCF="$PROJ_DIR/constraints/ulx5m_gs.ccf"
SDC="$PROJ_DIR/constraints/timing.sdc"
DEVICE="CCGM1A1"
TOP="fpga"

START_SEED=${1:-1}
END_SEED=${2:-200}
BEST_SEED=0
BEST_FREQ=0
RESULTS_FILE="$BUILD_DIR/seed_results.txt"

mkdir -p "$BUILD_DIR"

# Synthesis samo jednom
if [ ! -f "$BUILD_DIR/$TOP.json" ]; then
    echo "=== Synthesis (jednom) ==="
    yosys -l "$BUILD_DIR/synth.log" -q -p "
        read_verilog $RTL_DIR/fpga.v
        read_verilog $RTL_DIR/gatemate_25MHz_125MHz_pll.v
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
    echo "Synthesis done."
fi

echo "=== Seed Search: $START_SEED..$END_SEED ==="
echo "seed | clk_125_MHz | rx_clk_MHz | status" > "$RESULTS_FILE"
echo "-----|-------------|------------|-------" >> "$RESULTS_FILE"

for SEED in $(seq $START_SEED $END_SEED); do
    echo -n "Seed $SEED... "

    # PnR s timing-allow-fail
    nextpnr-himbaechel \
        --device "$DEVICE" \
        --json "$BUILD_DIR/$TOP.json" \
        --vopt "ccf=$CCF" \
        --vopt "out=$BUILD_DIR/${TOP}_s${SEED}.cfg" \
        --router router2 \
        --seed "$SEED" \
        --sdc "$SDC" \
        --placer-heap-cell-placement-timeout 20000 \
        --timing-allow-fail \
        --parallel-refine \
        > "$BUILD_DIR/pnr_s${SEED}.log" 2>&1

    # Izvuci frekvencije
    CLK125=$(grep "Max frequency for clock.*clk_125'" "$BUILD_DIR/pnr_s${SEED}.log" | grep -oP '[\d.]+(?= MHz)' | head -1)
    RXCLK=$(grep "Max frequency for clock.*rx_inst.clk'" "$BUILD_DIR/pnr_s${SEED}.log" | grep -oP '[\d.]+(?= MHz)' | head -1)

    CLK125=${CLK125:-0}
    RXCLK=${RXCLK:-0}

    # Provjeri da li je bolji
    PASS="FAIL"
    if (( $(echo "$CLK125 >= 125.0" | bc -l 2>/dev/null || echo 0) )); then
        PASS="PASS"
    fi

    echo "$SEED | $CLK125 | $RXCLK | $PASS" >> "$RESULTS_FILE"
    echo "clk_125=${CLK125} MHz, rx_clk=${RXCLK} MHz [$PASS]"

    # Track best
    if (( $(echo "$CLK125 > $BEST_FREQ" | bc -l 2>/dev/null || echo 0) )); then
        BEST_FREQ="$CLK125"
        BEST_SEED="$SEED"
    fi

    # Briši .cfg ako nije best (štedi disk)
    if [ "$SEED" != "$BEST_SEED" ]; then
        rm -f "$BUILD_DIR/${TOP}_s${SEED}.cfg"
    fi
done

echo ""
echo "========================================="
echo "BEST SEED: $BEST_SEED"
echo "BEST clk_125 Freq: $BEST_FREQ MHz"
echo "Config: $BUILD_DIR/${TOP}_s${BEST_SEED}.cfg"
echo "Results: $RESULTS_FILE"
echo "========================================="

# Ako best seed postoji, napravi bitstream
if [ -f "$BUILD_DIR/${TOP}_s${BEST_SEED}.cfg" ]; then
    echo "Packing best seed..."
    gmpack "$BUILD_DIR/${TOP}_s${BEST_SEED}.cfg" --bit "$BUILD_DIR/${TOP}_best.bit"
    echo "Bitstream: $BUILD_DIR/${TOP}_best.bit"
fi
