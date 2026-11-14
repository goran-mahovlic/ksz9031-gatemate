#!/bin/bash
# HW test of gbe_top (1000 Mb/s) on ULX5M-GS. Runs ON THE PI (shared lab, gs.owner lease).
#   hw_test_gbe.sh <gbe.bit> <restore.bit> [fpga_ip]
# STEP 1 lease, 2 CFGRST check, 3 load (fpga-jtag gs -r, no power cycle), 4 UART status (R31 = 0348
# is 1000FD), 5 ARP/ping sizes/UDP echo from this host, 6 hold: wait up to HOLD s (default 0) for
# "$OUT.done" (the throughput test runs on a gigabit host meanwhile,
# scripts/gbe_throughput.py), 7 UART again, 8 reload <restore.bit> (the board's previous design),
# 9 release. Log: $OUT (default ~/ulx5m-serdes/gbe/run.out), one STEP line per step.
set -u
BIT=$1; RESTORE=$2; IP=${3:-${FPGA_IP:-192.168.1.150}}
LEASE=${LAB_LEASE:-/home/pi/gs.owner}
OUT=${OUT:-$HOME/ulx5m-serdes/gbe/run.out}; mkdir -p "$(dirname "$OUT")"; : > "$OUT"; rm -f "$OUT.done"
HOLD=${HOLD:-0}
log() { echo "$*" | tee -a "$OUT"; }
CHECK=${CHECK:-$HOME/ulx5m-serdes/tools/gm_cfgrst_check.py}
TASK=${TASK:-TASK-6100}
OWN="$TASK $(date +%s) gbe 1000M ping+throughput test (kosjenka) pid=$$ log=$OUT"

if [ -e /home/pi/.lab.lock ] || { [ -s "$LEASE" ] && ! grep -q "^$TASK " "$LEASE"; }; then
  log "LAB BUSY: $(cat "$LEASE" 2>/dev/null) $(ls /home/pi/.lab.lock 2>/dev/null)"; exit 3
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

log "STEP 1/9 lease $OWN"
log "STEP 2/9 cfgrst $(sha256sum "$BIT" | cut -c1-16) $(basename "$BIT")"
python3 "$CHECK" "$BIT" 2>&1 | tee -a "$OUT" || { log "NO CFGRST - abort"; exit 2; }
log "STEP 3/9 load fpga-jtag gs $BIT -r"
fpga-jtag gs "$BIT" -r >>"$OUT" 2>&1 || { log "LOAD FAIL"; exit 1; }
T0=$(date +%s.%N)
log "STEP 4/9 uart 8s"
uart 8
log "STEP 5/9 net $IP"
sudo -n ip neigh del "$IP" dev eth0 2>/dev/null
ping -D -i 0.2 -W 1 -c 60 "$IP" > "$OUT.ping0" 2>&1
FIRST=$(grep -m1 "bytes from" "$OUT.ping0" | sed 's/^\[\([0-9.]*\)\].*/\1/')
log "first reply after load: $( [ -n "$FIRST" ] && python3 -c "print(round($FIRST-$T0,2))" || echo NONE ) s; $(grep -E 'transmitted' "$OUT.ping0")"
log "neigh: $(ip neigh show "$IP")"
for s in 0 56 100 1000 1472; do
  log "ping -s $s: $(ping -c 10 -W 1 -i 0.2 -s $s "$IP" 2>&1 | grep -E 'transmitted|rtt' | tr '\n' ' ')"
done
python3 - "$IP" <<'PY' | tee -a "$OUT"
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1.0)
for size in (14, 1472):
    ok = 0
    for i in range(20):
        m = (b"gs-gbe-%02d-" % i).ljust(size, b"x")
        s.sendto(m, (sys.argv[1], 1234))
        try:
            d, a = s.recvfrom(2048); ok += (d == m)
        except socket.timeout: pass
    print("UDP echo port 1234, %d B: %d/20" % (size, ok))
PY
log "STEP 6/9 hold ${HOLD}s for the throughput test (ends early when $OUT.done exists)"
END=$(( $(date +%s) + HOLD ))
while [ "$(date +%s)" -lt "$END" ] && [ ! -e "$OUT.done" ]; do sleep 1; done
log "hold over: $( [ -e "$OUT.done" ] && echo done-file || echo timeout )"
log "STEP 7/9 uart 3s"
uart 3
log "STEP 8/9 restore fpga-jtag gs $(basename "$RESTORE") -r"
fpga-jtag gs "$RESTORE" -r >>"$OUT" 2>&1 && log "restore OK" || log "RESTORE FAIL"
log "STEP 9/9 release"
