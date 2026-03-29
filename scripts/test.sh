#!/bin/bash
# Test Ethernet connectivity after flashing
# Usage: ./test.sh

RPI="fpga-klaudio@192.168.10.18"
FPGA_IP="192.168.10.150"
FPGA_MAC="10:e2:d5:00:00:00"

echo "=== [1/4] ARP Test (25 seconds) ==="
echo "Sending ARP requests to $FPGA_IP..."
ssh "$RPI" "timeout 25 arping -I eth0 $FPGA_IP -c 5" 2>/dev/null
ARP_RESULT=$?

echo ""
echo "=== [2/4] ARP Table Check ==="
ssh "$RPI" "arp -n | grep -i '$FPGA_IP\|$FPGA_MAC'" 2>/dev/null

echo ""
echo "=== [3/4] Ping Test ==="
ssh "$RPI" "ping -c 3 -W 2 $FPGA_IP" 2>/dev/null

echo ""
echo "=== [4/4] UDP Test ==="
echo "Sending UDP to port 9999... (press Ctrl+C to stop)"
echo "On RPi, run: nc -u $FPGA_IP 9999"

if [ $ARP_RESULT -eq 0 ]; then
    echo ""
    echo "*** ARP PASSED — FPGA is responding! ***"
else
    echo ""
    echo "*** ARP FAILED — Check TX timing ***"
    echo "Try MDIO fix: ssh $RPI 'echo w P 14 03FF s | nc -u $FPGA_IP 9999'"
fi
