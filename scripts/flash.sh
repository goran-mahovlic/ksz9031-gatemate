#!/bin/bash
# Flash bitstream to ULX5M-GS via RPi
# Usage: ./flash.sh [bitstream.bit]

RPI="fpga-klaudio@192.168.10.18"
RPI_DIR="/home/fpga-klaudio/FPGA"
BITSTREAM="${1:-build/fpga.bit}"

if [ ! -f "$BITSTREAM" ]; then
    echo "ERROR: Bitstream not found: $BITSTREAM"
    echo "Run build.sh first!"
    exit 1
fi

echo "=== Copying bitstream to RPi ==="
scp "$BITSTREAM" "$RPI:$RPI_DIR/fpga.bit"

echo "=== Flashing via openFPGALoader ==="
ssh "$RPI" "cd $RPI_DIR && openFPGALoader -c dirtyJtag fpga.bit"

echo "=== Flash complete ==="
