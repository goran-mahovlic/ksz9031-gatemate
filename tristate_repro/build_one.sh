#!/bin/bash
# Build a single repro design and dump the resulting CC_IOBUF cell + bitstream tile.
# Usage: ./build_one.sh <name>  where <name> is min_t_const, min_t_signal, or min_assign.
set -e
NAME="$1"
if [ -z "$NAME" ]; then echo "Usage: $0 {min_t_const|min_t_signal|min_assign}"; exit 1; fi

# Toolchain location: override with OSS_CAD_SUITE=/path/to/oss-cad-suite
export PATH="${OSS_CAD_SUITE:-$HOME/Programs/oss-cad-suite}/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/build_$NAME"
rm -rf "$OUT" && mkdir -p "$OUT"

DEVICE=CCGM1A1

echo "=== synth $NAME ==="
yosys -q -l "$OUT/synth.log" -p "
    read_verilog $DIR/$NAME.v
    synth_gatemate -top fpga -nomx8 -json $OUT/$NAME.json
"

echo "=== JSON: CC_IOBUF cell ==="
python3 -c "
import json
with open('$OUT/$NAME.json') as f: j = json.load(f)
mods = j['modules']
for mname, m in mods.items():
    for cname, c in m.get('cells', {}).items():
        if c['type'] in ('CC_IOBUF', 'CC_TOBUF', 'CC_OBUF'):
            print(f'  {cname}  type={c[\"type\"]}  conn={c[\"connections\"]}')
"

# PnR + pack only if user has a CCF (skip otherwise — JSON inspection is enough proof)
if [ -f "$DIR/$NAME.ccf" ]; then
    echo "=== PnR ==="
    nextpnr-himbaechel \
        --device "$DEVICE" \
        --json "$OUT/$NAME.json" \
        --vopt "ccf=$DIR/$NAME.ccf" \
        --vopt "out=$OUT/$NAME.cfg" \
        --router default 2>&1 | tee "$OUT/pnr.log" | grep -E "ERROR|WARNING|Constraining" | head -20

    echo "=== eth-pad GPIO tile in cfg ==="
    awk '/^.tile /{tile=$0} /GPIO\./{print tile, $0}' "$OUT/$NAME.cfg" | head -40
fi
