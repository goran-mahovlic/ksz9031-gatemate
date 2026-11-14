# ksz9031-gatemate

AI port of https://github.com/Lampranthus/KSZ9031RNXCC-PCB to the **ULX5M-GS**
(GateMate CCGM1A1 + Microchip KSZ9031RNX, RGMII), built with the open toolchain only.

## Status

| Design | Top | Speed | Hardware result |
|---|---|---|---|
| `eth100_top` (this README) | `rtl/eth100_top.v` | 100 Mb/s full duplex | **works**: MDIO ID read, link up 100FD, ARP + ping 0 % loss for every size up to `-s 1472`, UDP echo 20/20 (2026-11-14) |
| `fpga` (original 1 Gb/s port, `scripts/build.sh`) | `rtl/fpga.v` + `rtl/fpga_core.v` | 1 Gb/s | never sent a frame on this board, kept for reference |

1 Gb/s on this board is **not done here yet**; see "Next: 1 Gb/s" below.

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
commit `df934ee`, one SRAM load, no power cycle:

```
UART ID=0022:1622 BMSR=796D R31=0328 RXC=05F5E RX=0000 BAD=0000 TX=0000 ...
first reply after load: 4.22 s; 40 packets transmitted, 40 received, 0% packet loss
neigh: ... lladdr 10:e2:d5:00:00:00 REACHABLE
ping -s 0/56/100/1000/1472: 10/10 each, rtt avg 0.34 / 0.36 / 0.71 / 0.88 ms
UDP echo port 1234: 20/20
```

## Next: 1 Gb/s

At 1 Gb/s TXC is 125 MHz and the 90° offset can no longer come from a half-rate FF trick.
`litex-eth-ulx5m-gs-1g` (`gbe_phy.py`) has a GateMate 1G PHY recorded as pinging on this board at 1 Gb/s and
is the starting point for porting the 1G path into the `fpga` top. The MAC TX FIFO here is not a
frame FIFO, so at 1 Gb/s the stack would have to run on at least 125 MHz or the FIFO must buffer whole frames.

## Older material

`build_phase*`, `rtl/iobuf_test.v`, `tristate_repro/` and `scripts/decode_*.py` are the MDIO
debug history (UART-ILA, tri-state reproduction). `BRANCHES.md` records the remotes and the
publication status.
