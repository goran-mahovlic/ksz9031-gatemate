#!/bin/bash
# Seed sweep for gbe_top: synthesise once (build_gbe/), then place & route seeds in parallel
# (build_gbe/s<N>/). Prints post-route Fmax of gtx / rxc / clk and hold violations per seed.
#   seed_sweep_gbe.sh <first> <last> [jobs]
# On GateMate a seed whose 125 MHz domains PASS is not a guarantee and a FAIL is not a verdict
# (litex-eth-ulx5m-gs-1g ETH-1G-05): rank by the report, decide on the board.
set -euo pipefail
P="$(cd "$(dirname "$0")/.." && pwd)"
A=${1:-1}; B=${2:-8}; J=${3:-8}
SEED=$A "$P/scripts/build_gbe.sh" > "$P/build_gbe/sweep_s$A.out" 2>&1 || { tail "$P/build_gbe/sweep_s$A.out"; exit 1; }
mkdir -p "$P/build_gbe/s$A"; cp "$P/build_gbe/pnr.log" "$P/build_gbe/gbe_top.bit" "$P/build_gbe/s$A/"
seq $((A+1)) "$B" | xargs -P "$J" -I{} bash -c \
  'mkdir -p "$1/build_gbe/s$2"; JSON="$1/build_gbe/gbe_top.json" SEED=$2 OUT="$1/build_gbe/s$2" "$1/scripts/build_gbe.sh" > "$1/build_gbe/s$2/build.out" 2>&1 || echo "seed $2 failed"' _ "$P" {}
printf "%-5s %8s %8s %8s %5s\n" seed gtx rxc clk hold
for s in $(seq "$A" "$B"); do
  L="$P/build_gbe/s$s/pnr.log"; [ -f "$L" ] || continue
  f() { grep "Max frequency for clock" "$L" | grep "'$1'" | tail -1 | sed 's/.*: \([0-9.]*\) MHz.*/\1/'; }
  printf "%-5s %8s %8s %8s %5s\n" "$s" "$(f gtx)" "$(f phy_inst.rxc)" "$(f clk)" "$(grep -c 'Hold/min time violation for' "$L" || true)"
done
