#!/bin/bash
# Flash bitstream to ULX5M-GS via the JTAG host
# Usage: ./flash.sh [bitstream.bit]
#
# Connection settings come from scripts/lab.env (see scripts/lab.env.example)
# or from the RPI_HOST / RPI_DIR environment variables.
#
# No sudo and no password belong in this script. USB access to the DirtyJTAG
# dongle should be granted by a udev rule on the JTAG host, e.g. a rule that
# matches the dongle and assigns it to a group your login account is in.
# If openFPGALoader ever needs root, configure that on the host itself —
# a credential must NEVER be embedded here.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lab_env.sh"

BITSTREAM="${1:-build/fpga.bit}"

lab_env_banner

if [ ! -f "$BITSTREAM" ]; then
    echo "ERROR: Bitstream not found: $BITSTREAM"
    echo "Run build.sh first!"
    exit 1
fi

echo "=== Copying bitstream to $RPI_HOST ==="
if ! scp "$BITSTREAM" "$RPI_HOST:$RPI_DIR/fpga.bit"; then
    echo "ERROR: scp to $RPI_HOST failed"
    exit 1
fi

echo "=== Flashing via openFPGALoader ==="
if ! ssh "$RPI_HOST" "openFPGALoader -c dirtyJtag $RPI_DIR/fpga.bit"; then
    echo "ERROR: openFPGALoader failed"
    echo "Hint: if it reports 'DirtyJtag: fails to open device', check that the"
    echo "      dongle enumerated (lsusb); it may need a physical replug."
    exit 1
fi

echo "=== Flash complete ==="
