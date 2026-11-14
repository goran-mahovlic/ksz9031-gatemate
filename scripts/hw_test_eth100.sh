#!/bin/bash
# HW test of eth100_top on ULX5M-GS. Runs ON THE PI (shared lab, gs.owner lease).
#   hw_test_eth100.sh <eth.bit> <restore.bit> [fpga_ip]
# fpga_ip defaults to $FPGA_IP (scripts/lab.env on the build host), lease file to $LAB_LEASE.
# STEP 1 lease, 2 CFGRST check, 3 load (fpga-jtag gs -r, no power cycle), 4 UART status,
# 5 ARP/ping/UDP echo, 6 UART again, 7 reload <restore.bit> (the board's previous design), 8 release.
set -u
BIT=$1; RESTORE=$2; IP=${3:-${FPGA_IP:-192.168.1.150}}
LEASE=${LAB_LEASE:-$HOME/gs.owner}
OUT=${OUT:-$HOME/ulx5m-serdes/eth100/run.out}; mkdir -p "$(dirname "$OUT")"; : > "$OUT"
log() { echo "$*" | tee -a "$OUT"; }
CHECK=${CHECK:-$HOME/ulx5m-serdes/tools/gm_cfgrst_check.py}
TASK=${TASK:-TASK-6092}
OWN="$TASK $(date +%s) eth100 ping test (kosjenka) pid=$$ log=$OUT"

if [ -s "$LEASE" ] && ! grep -q "^$TASK " "$LEASE"; then
  log "LAB BUSY: $(cat "$LEASE")"; exit 3
fi
echo "$OWN" > "$LEASE"
release() { grep -q "pid=$$ " "$LEASE" 2>/dev/null && rm -f "$LEASE"; }
trap release EXIT

uart() {  # uart <seconds>
  python3 -u - "$(fpga-jtag uart gs)" "$1" <<'PY' | tee -a "$OUT"
import serial, sys, time
s = serial.Serial(sys.argv[1], 115200, timeout=0.2); s.reset_input_buffer()
end = time.time() + float(sys.argv[2]); buf = b""
while time.time() < end: buf += s.read(256)
for l in buf.decode("ascii", "replace").splitlines():
    if l.strip(): print("UART", l.strip())
PY
}

log "STEP 1/8 lease $OWN"
log "STEP 2/8 cfgrst $(sha256sum "$BIT" | cut -c1-16) $(basename "$BIT")"
python3 "$CHECK" "$BIT" 2>&1 | tee -a "$OUT" || { log "NO CFGRST - abort"; exit 2; }
log "STEP 3/8 load fpga-jtag gs $BIT -r"
fpga-jtag gs "$BIT" -r >>"$OUT" 2>&1 || { log "LOAD FAIL"; exit 1; }
T0=$(date +%s.%N)
log "STEP 4/8 uart 4s"
uart 4
log "STEP 5/8 net $IP"
sudo -n ip neigh del "$IP" dev eth0 2>/dev/null
ping -D -i 0.2 -W 1 -c 40 "$IP" > "$OUT.ping0" 2>&1
FIRST=$(grep -m1 "bytes from" "$OUT.ping0" | sed 's/^\[\([0-9.]*\)\].*/\1/')
log "first reply after load: $( [ -n "$FIRST" ] && python3 -c "print(round($FIRST-$T0,2))" || echo NONE ) s; $(grep -E 'transmitted' "$OUT.ping0")"
log "neigh: $(ip neigh show "$IP")"
for s in 0 56 100 1000 1472; do
  log "ping -s $s: $(ping -c 10 -W 1 -i 0.2 -s $s "$IP" 2>&1 | grep -E 'transmitted|rtt')"
done
python3 - "$IP" <<'PY' | tee -a "$OUT"
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1.0); ok = 0
for i in range(20):
    m = b"gs-eth100-%02d" % i
    s.sendto(m, (sys.argv[1], 1234))
    try:
        d, a = s.recvfrom(2048); ok += (d == m)
    except socket.timeout: pass
print("UDP echo port 1234: %d/20" % ok)
PY
log "STEP 6/8 uart 3s"
uart 3
log "STEP 7/8 restore fpga-jtag gs $(basename "$RESTORE") -r"
fpga-jtag gs "$RESTORE" -r >>"$OUT" 2>&1 && log "restore OK" || log "RESTORE FAIL"
log "STEP 8/8 release"
