#!/bin/bash
# Flash bitstream to ULX5M-GS via RPi
# Usage: ./flash.sh [bitstream.bit]
#
# NOTE (TASK-4737): no sudo, no password.
# USB access to the DirtyJTAG dongle is granted by a udev rule on the RPi:
#   /etc/udev/rules.d/60-dirtyjtag.rules  -> 04b4:0008 MODE=0660 GROUP=plugdev
# and fpga-klaudio is a member of plugdev. If openFPGALoader ever needs root
# again, a NOPASSWD sudoers entry exists (/etc/sudoers.d/011_fpga-klaudio-nopasswd)
# so a password must NEVER be embedded in this script.

RPI="fpga-klaudio@192.168.10.14"
RPI_DIR="/home/fpga-klaudio/FPGA"
BITSTREAM="${1:-build/fpga.bit}"

if [ ! -f "$BITSTREAM" ]; then
    echo "ERROR: Bitstream not found: $BITSTREAM"
    echo "Run build.sh first!"
    exit 1
fi

echo "=== Copying bitstream to RPi ==="
if ! scp "$BITSTREAM" "$RPI:$RPI_DIR/fpga.bit"; then
    echo "ERROR: scp to $RPI failed"
    exit 1
fi

echo "=== Flashing via openFPGALoader ==="
if ! ssh "$RPI" "openFPGALoader -c dirtyJtag $RPI_DIR/fpga.bit"; then
    echo "ERROR: openFPGALoader failed"
    echo "Hint: if it reports 'DirtyJtag: fails to open device', check that the"
    echo "      dongle enumerated (lsusb -d 04b4:0008); it may need a physical replug."
    exit 1
fi

echo "=== Flash complete ==="
