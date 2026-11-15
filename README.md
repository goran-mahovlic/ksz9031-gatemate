# ksz9031-gatemate

AI port of https://github.com/Lampranthus/KSZ9031RNXCC-PCB to the **ULX5M-GS**
(GateMate CCGM1A1 + Microchip KSZ9031RNX, RGMII), built with the open toolchain only.

## Status

| Design | Top | Speed | Hardware result |
|---|---|---|---|
| `gbe_top` | `rtl/gbe_top.v` + `rtl/gbe_rgmii.v` | 1000 Mb/s full duplex | **works**: link 1000FD (R31 = 0x0348), ping 0 % loss for every size up to `-s 1472`, UDP echo 20/20 (14 B and 1472 B), line-rate UDP burst 50 001 × 1472 B, 3/3 loads (2026-11-15), see "1 Gb/s: gbe_top" |
| `eth100_top` | `rtl/eth100_top.v` | 100 Mb/s full duplex | **works**: MDIO ID read, link up 100FD, ARP + ping 0 % loss for every size up to `-s 1472`, UDP echo 20/20, 3/3 loads (2026-11-14) |
| `fpga` (original 1 Gb/s port, `scripts/build.sh`) | `rtl/fpga.v` + `rtl/fpga_core.v` | 1 Gb/s | never sent a frame on this board, kept for reference |

## Quick start

```bash
OSS_CAD_SUITE=/path/to/oss-cad-suite-20261016 ./scripts/build_eth100.sh   # -> build_eth100/eth100_top.bit
OSS_CAD_SUITE=/path/to/oss-cad-suite-20261016 ./sim/eth100/run.sh         # end-to-end testbench, prints PASS
```

Load into SRAM only (`-r`, no power cycle). The bitstream is packed with `gmpack --reset`
(CMD_CFGRST): without it `-r` writes the sparse bitstream over what the previous design left in
the fabric. On the bench, the board is shared, so `scripts/hw_test_eth100.sh` (runs on the Pi
that owns the JTAG probe) takes the lab lease, checks CFGRST, loads, reads the UART, runs
ARP/ping/UDP, loads the previous design back and releases the lease:

```bash
hw_test_eth100.sh eth100_top.bit previous_design.bit <fpga_ip>
```

Network settings are the `eth_core` parameters in `rtl/eth_core.v` (`LOCAL_MAC` = `10:e2:d5:00:00:00`, `LOCAL_IP`, `GATEWAY_IP`, `SUBNET`, UDP echo port 1234); set `LOCAL_IP` for your network.

### UART status line

115200 8N1 on `IO_NB_B5` (reaches the DirtyJTAG bridge UART) and, as a copy, on `IO_NA_A4`. One line per second:

```
ID=0022:1622 BMSR=796D R31=0328 RXC=05F5E RX=0018 BAD=0000 TX=0015 ICMP=0014 UDP=0000 TRY=00
```

`ID` = PHY registers 2:3 at PHYAD 3, `BMSR` bit 2 = link, `R31` = KSZ9031 PHY control
(0x0328 = 100 Mb/s full duplex), `RXC` = RX clock in units of 1024 Hz (0x5F5E = 25.0 MHz),
`RX/BAD/TX/ICMP/UDP` = frame counters, `TRY` = MDIO init retries.

LEDs: 0 heartbeat, 1 PHY ID ok, 2 link, 3 100FD, 4 RX frame, 5 TX frame, 6 ICMP reply, 7 RXC alive.

## What makes it work (and what was wrong before)

The working recipe comes from the LiteX design on the same board that pings
(`litex-eth-ulx5m-gs`, tag `eth100-ping-ok-20260924`, profile `x1`), re-implemented here in plain Verilog.

| Topic | Finding | In this design |
|---|---|---|
| PHY address | KSZ9031 strap gives **PHYAD 3** (ID 0x0022:0x1622 read back there) | `mdio_phy_init #(.PHYAD(3))`, no address scan |
| PHY XI clock | On boards with the X1 oscillator XI comes from X1. Driving `IO_EB_A3` is not needed (it was used with DRIVE=6 on boards without X1) | `IO_EB_A3` not in the constraints |
| MDIO | The old "MDIO always reads 0x0000 / FPGA does not hold the line" was the tri-state instantiation, not the silicon: `CC_IOBUF` works when T comes from a register (constant T trips nextpnr), see `rtl/iobuf_test.v` | `CC_IOBUF` + `keep`, T = registered `~mdio_oe`, pull-up |
| Advertisement | Autoneg to 100FD only: reg 9 = 0x0000, reg 4 = 0x0101, reg 0 = 0x1200 | written once after the PHY reset |
| TX timing | KSZ9031 adds **no** delay on TXC/TXD/TX_CTL (DS00002117F p. 22), so TXC must sit 90° off the data. A CLK90 net routed through fabric to the pad took 6–7 ns and moved with every seed | "io50": TXD/TX_CTL are IOSEL flip-flops (`FF_OBF`) on 50 MHz that change every 2nd cycle; TXC is an IOSEL flip-flop on the PLL's CLK180 sampling the phase bit → TXC rises 10 ns after a data change and falls 10 ns before the next |
| PLL | The TASK-4999 note "PLL#1 (eth_tx) = 0 cycles" did not reproduce: the same bitstream later measured a running PLL#1. What does matter is the mode: LOWPOWER did not lock reliably, ECONOMY/SPEED did | one `CC_PLL`, ECONOMY, 25 → 50 MHz (CLK0 + CLK180) |
| Clock domains | With the whole stack on 50 MHz the routed clock closed at only 40–47 MHz (8 seeds) | the stack, MDIO and UART run on the 25 MHz pad clock; only MAC TX + TX pads are on 50 MHz (as in LiteX: sys 16 MHz, eth_tx 50 MHz) |
| RX | RXC is 25 MHz at 100 Mb/s; both DDR halves carry the same nibble | `CC_IDDR` on RXC, rising-edge half |
| PHY reset | RESET_N needs ≥ 10 ms | held low 42 ms after configuration, restarted only by `CC_USR_RSTN` |
| UART pins | the DirtyJTAG bridge UART is on `IO_NB_B5`/`IO_NA_B6` (the old constraints used `IO_NA_A4`/`IO_NA_B4`, the v0.3 carrier pinout) | `IO_NB_B5` (TX), `IO_NA_B6` (RX), TX copied to `IO_NA_A4` |
| Bitstream | `-r` without CMD_CFGRST loads over the previous design | `gmpack --reset` in `build_eth100.sh` |
| Clock pins | `CC_BUFG` on a pin that is not a dedicated clock input is fine in nextpnr (user_glb) | the 25 MHz pad drives a global directly |

### Bugs found by the end-to-end testbench

`sim/eth100/tb_eth100.v` drives the RGMII pins like the PHY (MDIO slave at PHYAD 3, RX frames,
TX capture + FCS check, UART decoder). It found four RTL bugs that the old design also had:

1. `rtl/gm_arp.v`: `arp_request_ready` went high one cycle before the request flags were valid.
   `ip_eth_tx` drops `valid` after the handshake, so the lookup was lost and **every IP reply
   (ICMP, UDP) hung forever** while ARP replies still worked. Ready is now gated with the flag.
2. `rtl/gm_arp.v`: the 36-bit `timer == 0` compare fed the outgoing-frame muxes (22.9 ns path);
   it is registered now. ARP retry/timeout constants are set for 25 MHz in `eth_core.v`.
3. `rtl/eth_core.v`: the UDP echo cleared its port-match flag before the payload arrived, so the
   payload was never accepted.
4. `rtl/gm_eth_mac_1g_fifo.v`: the TX FIFO was a synchronous FIFO on `logic_clk` feeding a MAC
   on `tx_clk`, i.e. it silently required both clocks to be the same. It is an async FIFO now.
   (`gm_*_fifo.v`: the read register also only advances on a read.)

## Build results (oss-cad-suite-20261016, seed 1)

yosys 0.70+145, nextpnr-himbaechel 0.11.1-63, gmpack v1.13-6. After routing: `clk` (stack,
25 MHz) 37 MHz, `clk50` (MAC TX) 75 MHz, RXC 51 MHz, 0 hold violations.

## Hardware test, 2026-11-14

Board: ULX5M-GS on the CM5-IO-BASE-A carrier (HanRun RJ45). Bitstream sha256 `627a831469b41024…`,
commit `df934ee`, three SRAM loads (`-r`, no power cycle), all PASS with the same numbers (first reply after load 4.22 / 4.34 / 4.32 s). Run 1:

```
UART ID=0022:1622 BMSR=796D R31=0328 RXC=05F5E RX=0000 BAD=0000 TX=0000 ...
first reply after load: 4.22 s; 40 packets transmitted, 40 received, 0% packet loss
neigh: ... lladdr 10:e2:d5:00:00:00 REACHABLE
ping -s 0/56/100/1000/1472: 10/10 each, rtt avg 0.34 / 0.36 / 0.71 / 0.88 ms
UDP echo port 1234: 20/20
```

After each run the UART counters matched the traffic exactly: `ICMP=005A` (90 = 40 + 5×10 pings), `UDP=0014` (20), `BAD=0000`.

## 1 Gb/s: gbe_top

```bash
OSS_CAD_SUITE=/path/to/oss-cad-suite-20261016 ./scripts/build_gbe.sh          # -> build_gbe/gbe_top.bit
OSS_CAD_SUITE=/path/to/oss-cad-suite-20261016 ./scripts/seed_sweep_gbe.sh 1 14 # seeds in build_gbe/s<N>/
OSS_CAD_SUITE=/path/to/oss-cad-suite-20261016 ./sim/gbe/run.sh                # PASS; RX_LATE=1 for the other RX pairing
hw_test_gbe.sh gbe_top.bit previous_design.bit <fpga_ip>                      # on the Pi, as hw_test_eth100.sh
```

The stack (MAC, ARP/IP/ICMP/UDP echo) is the one of `eth100_top` and stays on the 25 MHz pad clock; the
Forencich MAC runs in GMII byte mode on that clock. `rtl/gbe_rgmii.v` is a Verilog port of the GateMate
1G PHY that pings on this board in `litex-eth-ulx5m-gs-1g` (`gateware/gbe_phy.py`, tag
`gbe-1000m-ping-ok-20260925`):

| Topic | In this design |
|---|---|
| Clocks | one `CC_PLL` (ECONOMY) 25 -> 125 MHz: CLK0 = gtx (TX serializer, `CC_ODDR`), CLK90 -> `CC_BUFG` -> TXC pad (~2 ns after the data, like RGMII-ID; KSZ9031 adds no TX delay). RXC -> `CC_BUFG` -> `CC_IDDR`. Global nets: clk25, gtx, TXC, RXC = all 4 |
| 125 MHz logic | only IO registers, the RX nibble aligner (pairing A or B, chosen by where the SFD shows up), 4-byte shift registers and a 36-bit BRAM port that moves once every 4 cycles; next-state functions of <= 4 inputs |
| Clock crossing | store-and-forward of whole frames through a 4 KiB BRAM per direction; the slow side sees complete frames only. TX frames that do not fit are dropped whole (`DRP`), RX frames that do not fit too (`RD`) |
| MDIO | 1000FD only: reg 9 = 0x0200, reg 4 = 0x0001, reg 0 = 0x1200 -> R31 = 0x0348 |
| Burst (throughput) | a datagram to UDP **1235** is echoed and the echo goes on the wire 1 + 50 000 times back to back (IFG 12 B), by rewinding the gtx read pointer; every copy is the same valid frame. `BST` counts finished bursts |

UART line (as eth100, plus four fields):

```
ID=0022:1622 BMSR=796D R31=0348 RXC=1DCDA RX=.... BAD=0000 TX=.... ICMP=.... UDP=.... TRY=00 DRP=0000 BST=0003 RD=00 FL=00
```

`RXC=1DCDA` = 125.0 MHz, `DRP` = TX frames dropped, `BST` = bursts done, `RD` = RX frames dropped,
`FL` = RX pairing changes. The frame that first shows the other nibble pairing only switches the aligner and
is lost (as in `gbe_phy.py`); on this board the pairing is A, so `FL` stays 0.

### Simulation (`sim/gbe/tb_gbe.v`)

PHY model with 125 MHz DDR on RXC/TXC, PASS for both RX pairings (`RX_LATE=0/1`): MDIO 1000FD advert,
ARP, ICMP 64/1000/1472 B, two pings back to back, UDP echo, burst 6/6 identical frames at **955.8 Mb/s
UDP payload** (frame period 12.32 µs), TXD/TX_CTL setup and hold 2.0 ns around TXC, and "ARP under load"
(below). `sim/eth100` still PASS.

### Bug fixed on the way: UDP echo froze the stack under a flood from a new host

The echo let the RX header wait for the TX header (the verilog-ethernet example pattern). The TX header
waits for the ARP lookup of the sender, the ARP reply sits behind the stalled datagram, so the lookup can
only time out (30 s) and the next datagram starts it again. On the board a UDP flood to 1234 from a host not
yet in the ARP cache froze RX completely until the next load. `rtl/eth_core.v` now always takes the RX
header: one echo header register + payload FIFO, and a datagram is dropped while an echo is pending or the
FIFO has no room for it. The testbench phase "ARP under load" (24 back-to-back datagrams from an unknown
host, then ARP replies) passes with the new echo and fails with the old one (0 echoes, ping never answered).

### Build (oss-cad-suite-20261016, seed 13)

`CPE_LT` 12078 / 40960 (29 %), `RAM_HALF` 10 / 64, 0 hold violations. After routing: rxc 143.9 MHz,
clk 45.1 MHz, gtx 116.0 MHz. The gtx path that "fails" is `go` -> shift-register mux: `go` is set in phase 0
and only used when the shift register loads in phase 3, so it has 3 cycles in practice. As in
`litex-eth-ulx5m-gs-1g` (ETH-1G-05) the seed is chosen on the board, not by the report.

### Hardware test, 2026-11-15

ULX5M-GS on CM5-IO-BASE-A, switch with a gigabit port to the board. Bitstream seed 13, sha256
`75f0d63ec3ea3417…`, commit `39be983`, three SRAM loads (`-r`), all PASS:

```
UART ID=0022:1622 BMSR=796D R31=0348 RXC=1DCDA ... BAD=0000 ... DRP=0000 ... FL=00
first reply after load: 8.26 / 10.54 / 8.31 s; 60/60
ping -s 0/56/100/1000/1472: 10/10 each (rtt avg 0.35 / 0.35 / 0.61 / 0.76 ms at 1472)
UDP echo port 1234, 14 B: 20/20; 1472 B: 20/20
```

The build before the echo fix (seed 12, sha256 `91b83a5b0611d038…`, commit `fe5638a`) passed the same ping and
UDP checks on 4 loads; on the 4th the echo flood froze it (the bug below).

Throughput, measured from node-A (a VM bridged on the LAN; the Pi and dell-home are on 100 Mb/s ports):

| Test | Result |
|---|---|
| burst FPGA -> host, 50 001 × 1472 B (`scripts/udp_burst_rx.c`) | sent at line rate by construction (12.32 µs per frame = 955.8 Mb/s payload, 1000 Mb/s on the wire, see sim). Received: 50 001 / 50 001 (0 % loss) in one run (seed 12), otherwise 85–98 %; the receiving VM itself measured up to **872.9 Mb/s payload (912 Mb/s on the wire)** for 49 216 / 50 001; in most runs the VM drains at ~600 Mb/s. Kernel `RcvbufErrors` 0, i.e. the losses happen in the VM host, not on the link |
| UDP echo host -> FPGA -> host, 1472 B (`scripts/udp_echo_blast.c`) | 50 Mb/s: 0.02–0.06 % loss; 100 Mb/s: 0.5–1.9 %; best 175 Mb/s in -> 158–160 Mb/s echoed (9 % loss), 225 in -> 175.5 Mb/s once. Above ~150 Mb/s the loss varies a lot between runs (2 % to 98 %): the VM sends in bursts, and the 4 KiB RX buffer holds two frames |
| RX FCS at 1000 Mb/s | `BAD=0000` after every run (> 46 000 frames in one run) |

The echo ceiling is the 25 MHz stack (one byte per clock ≈ 190 Mb/s payload); the 1 Gb/s line itself is
shown by the burst. Next steps for a faster echo: a deeper RX buffer (`AW = 12`) and the stack on a faster
clock or a wider datapath.

## Older material

`build_phase*`, `rtl/iobuf_test.v`, `tristate_repro/` and `scripts/decode_*.py` are the MDIO
debug history (UART-ILA, tri-state reproduction). `BRANCHES.md` records the remotes and the
publication status.
