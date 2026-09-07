#!/bin/bash
# Test Ethernet connectivity after flashing
# Usage: ./test.sh
#
# Connection settings come from scripts/lab.env (see scripts/lab.env.example)
# or from the TEST_RPI_HOST / FPGA_IP / FPGA_MAC environment variables.
# TEST_RPI_HOST falls back to RPI_HOST when it is not set.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lab_env.sh"

lab_env_banner

echo "=== [1/4] ARP Test (25 seconds) ==="
echo "Sending ARP requests to $FPGA_IP..."
ssh "$TEST_RPI_HOST" "timeout 25 arping -I eth0 $FPGA_IP -c 5" 2>/dev/null
ARP_RESULT=$?

echo ""
echo "=== [2/4] ARP Table Check ==="
ssh "$TEST_RPI_HOST" "arp -n | grep -i '$FPGA_IP\|$FPGA_MAC'" 2>/dev/null

echo ""
echo "=== [3/4] Ping Test ==="
ssh "$TEST_RPI_HOST" "ping -c 3 -W 2 $FPGA_IP" 2>/dev/null

echo ""
echo "=== [4/4] UDP Test ==="
echo "Sending UDP to port 9999... (press Ctrl+C to stop)"
echo "On the JTAG host, run: nc -u $FPGA_IP 9999"

if [ $ARP_RESULT -eq 0 ]; then
    echo ""
    echo "*** ARP PASSED — FPGA is responding! ***"
else
    echo ""
    echo "*** ARP FAILED — Check TX timing ***"
    echo "Try MDIO fix: ssh $TEST_RPI_HOST 'echo w P 14 03FF s | nc -u $FPGA_IP 9999'"
fi
