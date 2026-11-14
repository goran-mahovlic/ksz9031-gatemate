/*
 * gbe_top.v — 1000 Mb/s RGMII Ethernet for ULX5M-GS (GateMate CCGM1A1 + KSZ9031RNX), no SoC
 *
 * Same stack as eth100_top (Forencich MAC + ARP/IP/ICMP/UDP echo on the 25 MHz pad clock), but the
 * MAC runs in GMII byte mode on clk and gbe_rgmii carries whole frames to/from the 125 MHz RGMII:
 *
 *  Clock   : 25 MHz IO_SB_A8 = logic clock (stack, MAC, MDIO, UART) and PLL reference.
 *            CC_PLL (ECONOMY) 25 -> 125 MHz: CLK0 = gtx (TX serializer + CC_ODDR), CLK90 -> CC_BUFG ->
 *            TXC pad. KSZ9031 adds no delay on TXC/TXD (DS00002117F p. 22): CLK90 through the BUFG
 *            reaches the pad ~2 ns after the data (as RGMII-ID); without the BUFG the fabric route
 *            took 5.8 ns and no frame got through (litex-eth-ulx5m-gs-1g, TASK-5032, ETH-1G-03).
 *            Global nets: clk25, gtx, TXC, RXC = all 4 of the CCGM1A1.
 *  RX      : RXC (IO_EB_A7) -> CC_BUFG -> CC_IDDR + aligner in gbe_rgmii.
 *  MDIO    : PHYAD 3, 1000FD-only advert: reg9 = 0x0200, reg4 = 0x0001, reg0 = 0x1200 -> R31 = 0x0348.
 *  Echo    : ICMP; UDP echo on 1234; UDP echo on 1235 = burst: the echo goes on the wire 1 + BURST_N
 *            times at line rate (throughput test, see gbe_rgmii.v).
 *  UART    : TX IO_NB_B5 / RX IO_NA_B6, 115200 8N1, one status line/s (uart_status EXT=1).
 *
 * LEDs: 0 heartbeat, 1 MDIO ID ok, 2 link up, 3 1000FD, 4 RX frame, 5 TX frame, 6 ICMP, 7 RXC alive
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gbe_top #(
    parameter        PHY_RST_BIT  = 20,                 // RESET_N low for 2^20 clk25 = 42 ms
    parameter [23:0] MDIO_SETTLE  = 24'd2_500_000,      // 100 ms before the first MDIO access
    parameter [23:0] MDIO_POLL    = 24'd1_250_000,      // 50 ms between MDIO poll rounds
    parameter [25:0] STATUS_TICKS = 26'd24_999_999,     // one UART status line per second
    parameter [15:0] BURST_N      = 16'd50000,          // extra copies per burst datagram
    parameter        UART_BAUD    = 115_200             // simulation uses a faster UART
) (
    input  wire       clk_25mhz,
    output wire [7:0] led,
    output wire       uart_tx,
    output wire       uart_tx_alt,  // same line on IO_NA_A4 (older carrier wiring)
    input  wire       uart_rx,

    output wire       eth_tx_clk,
    output wire [3:0] eth_txd,
    output wire       eth_tx_ctl,
    input  wire       eth_rx_clk,
    input  wire [3:0] eth_rxd,
    input  wire       eth_rx_ctl,
    output wire       eth_rst_n,
    output wire       eth_mdc,
    inout  wire       eth_mdio
);

// ------------------------------------------------------------------ clocks
wire gtx, clk125_90, txc;
wire pll_locked, pll_locked_stdy;

CC_PLL #(
    .REF_CLK("25.0"),
    .OUT_CLK("125.0"),
    .PERF_MD("ECONOMY"),
    .LOW_JITTER(1),
    .CI_FILTER_CONST(2),
    .CP_FILTER_CONST(4),
    .LOCK_REQ(1)
) pll_inst (
    .CLK_REF(clk_25mhz),
    .CLK_FEEDBACK(1'b0),
    .USR_CLK_REF(1'b0),
    .USR_LOCKED_STDY_RST(1'b0),
    .USR_PLL_LOCKED_STDY(pll_locked_stdy),
    .USR_PLL_LOCKED(pll_locked),
    .CLK0(gtx),
    .CLK90(clk125_90),
    .CLK180(),
    .CLK270(),
    .CLK_REF_OUT()
);

CC_BUFG txc_bufg (.I(clk125_90), .O(txc));

wire rxc;
CC_BUFG rxc_bufg (.I(eth_rx_clk), .O(rxc));

wire usr_rstn;
CC_USR_RSTN usr_rstn_inst (.USR_RSTN(usr_rstn));

wire clk = clk_25mhz;

// ------------------------------------------------------------------ resets (clk)
reg [PHY_RST_BIT:0] phy_rst_cnt = 0;
always @(posedge clk) begin
    if (!usr_rstn)
        phy_rst_cnt <= 0;
    else if (!phy_rst_cnt[PHY_RST_BIT])
        phy_rst_cnt <= phy_rst_cnt + 1'b1;
end
wire phy_out_of_reset = phy_rst_cnt[PHY_RST_BIT];
assign eth_rst_n = phy_out_of_reset;

reg [15:0] por_cnt = 16'd0;
reg        rst = 1'b1;
always @(posedge clk) begin
    if (!usr_rstn) begin
        por_cnt <= 16'd0;
        rst     <= 1'b1;
    end else if (!por_cnt[15]) begin
        por_cnt <= por_cnt + 16'd1;
        rst     <= 1'b1;
    end else begin
        rst     <= 1'b0;
    end
end

// ------------------------------------------------------------------ RGMII 1000 <-> GMII bytes on clk
wire [7:0]  gmii_txd, gmii_rxd;
wire        gmii_tx_en, gmii_tx_er, gmii_rx_dv;
wire [15:0] tx_drops, tx_bursts, phy_rx_frames;
wire [7:0]  rx_drops, rx_flips;

gbe_rgmii #(
    .BURST_PORT(16'd1235),
    .BURST_N(BURST_N)
) phy_inst (
    .clk(clk),
    .gtx(gtx),
    .txc_in(txc),
    .rxc(rxc),
    .s_txd(gmii_txd),
    .s_tx_en(gmii_tx_en),
    .s_rxd(gmii_rxd),
    .s_rx_dv(gmii_rx_dv),
    .rgmii_txc(eth_tx_clk),
    .rgmii_txd(eth_txd),
    .rgmii_tx_ctl(eth_tx_ctl),
    .rgmii_rxd(eth_rxd),
    .rgmii_rx_ctl(eth_rx_ctl),
    .tx_drops(tx_drops),
    .tx_bursts(tx_bursts),
    .rx_frames(phy_rx_frames),
    .rx_drops(rx_drops),
    .rx_flips(rx_flips)
);

// ------------------------------------------------------------------ MAC + stack (all on clk)
wire [15:0] rx_frames, rx_bad, tx_frames, icmp_count, udp_count;

eth_core #(
    .MII_SELECT(0),
    .UDP_PORT2(16'd1235)
) core_inst (
    .clk(clk),
    .rst(rst),
    .tx_clk(clk),
    .tx_rst(rst),
    .rx_clk(clk),
    .rx_rst(rst),
    .gmii_rxd(gmii_rxd),
    .gmii_rx_dv(gmii_rx_dv),
    .gmii_rx_er(1'b0),
    .gmii_txd(gmii_txd),
    .gmii_tx_en(gmii_tx_en),
    .gmii_tx_er(gmii_tx_er),
    .tx_clk_enable(1'b1),
    .rx_frames(rx_frames),
    .rx_bad(rx_bad),
    .tx_frames(tx_frames),
    .icmp_count(icmp_count),
    .udp_count(udp_count)
);

// ------------------------------------------------------------------ MDIO
wire mdio_o, mdio_oe, mdio_i;
wire [15:0] id1, id2, bmsr, phyctl;
wire        mdio_init_done;
wire [7:0]  mdio_tries;

mdio_phy_init #(
    .PHYAD(5'd3),
    .MDC_DIV(20),                 // 25 MHz / 20 = 1.25 MHz MDC
    .SETTLE(MDIO_SETTLE),
    .POLL_GAP(MDIO_POLL),
    .G1000(1)
) mdio_inst (
    .clk(clk),
    .rst(rst || !phy_out_of_reset),
    .mdc(eth_mdc),
    .mdio_o(mdio_o),
    .mdio_oe(mdio_oe),
    .mdio_i(mdio_i),
    .id1(id1),
    .id2(id2),
    .bmsr(bmsr),
    .phyctl(phyctl),
    .init_done(mdio_init_done),
    .init_tries(mdio_tries)
);

// GateMate CC_IOBUF: T = 1 -> high-Z. T comes from a register (constant T trips nextpnr).
(* keep *)
CC_IOBUF #(
    .PULLUP(1)
) mdio_iobuf (
    .A(mdio_o),
    .T(~mdio_oe),
    .Y(mdio_i),
    .IO(eth_mdio)
);

// ------------------------------------------------------------------ RXC frequency meter
reg [9:0] rxc_div = 10'd0;
always @(posedge rxc)
    rxc_div <= rxc_div + 10'd1;

reg [2:0]  rxc_sync = 3'd0;
reg [25:0] sec_cnt  = 26'd0;
reg [19:0] rxc_edges, rxc_freq;
reg        tick_1s;
always @(posedge clk) begin
    rxc_sync <= {rxc_sync[1:0], rxc_div[9]};
    tick_1s  <= 1'b0;
    if (rst) begin
        sec_cnt   <= 26'd0;
        rxc_edges <= 20'd0;
        rxc_freq  <= 20'd0;
    end else begin
        if (rxc_sync[2] != rxc_sync[1])
            rxc_edges <= rxc_edges + 20'd1;
        if (sec_cnt == STATUS_TICKS) begin
            sec_cnt   <= 26'd0;
            rxc_freq  <= rxc_edges;
            rxc_edges <= 20'd0;
            tick_1s   <= 1'b1;
        end else begin
            sec_cnt <= sec_cnt + 26'd1;
        end
    end
end

// ------------------------------------------------------------------ UART status
// tx_bursts / rx_drops / rx_flips come from the 125 MHz domains; they are read quasi-statically
// (a torn read only garbles one status line).
uart_status #(
    .CLK_HZ(25_000_000),
    .BAUD(UART_BAUD),
    .EXT(1)
) status_inst (
    .clk(clk),
    .rst(rst),
    .trigger(tick_1s),
    .id1_i(id1), .id2_i(id2), .bmsr_i(bmsr), .phyctl_i(phyctl),
    .rxcf_i({1'b0, rxc_freq[19:1]}),
    .rxf_i(rx_frames), .bad_i(rx_bad), .txf_i(tx_frames),
    .icmp_i(icmp_count), .udp_i(udp_count),
    .tries_i(mdio_tries),
    .drp_i(tx_drops), .bst_i(tx_bursts), .rdr_i(rx_drops), .flp_i(rx_flips),
    .txd(uart_tx)
);
assign uart_tx_alt = uart_tx;

// ------------------------------------------------------------------ LEDs (active high)
reg [15:0] rx_last, tx_last, icmp_last;
reg [20:0] rx_led = 0, tx_led = 0, icmp_led = 0;
always @(posedge clk) begin
    rx_last   <= rx_frames;
    tx_last   <= tx_frames;
    icmp_last <= icmp_count;
    rx_led    <= (rx_last   != rx_frames)  ? 21'h1FFFFF : (rx_led   != 0 ? rx_led   - 21'd1 : 21'd0);
    tx_led    <= (tx_last   != tx_frames)  ? 21'h1FFFFF : (tx_led   != 0 ? tx_led   - 21'd1 : 21'd0);
    icmp_led  <= (icmp_last != icmp_count) ? 21'h1FFFFF : (icmp_led != 0 ? icmp_led - 21'd1 : 21'd0);
end

assign led[0] = sec_cnt > (STATUS_TICKS >> 1);
assign led[1] = (id1 == 16'h0022) && (id2[15:4] == 12'h162);
assign led[2] = bmsr[2];
assign led[3] = (phyctl[6:3] == 4'b1001);   // reg 0x1F: bit6 = 1000M, bit3 = FD
assign led[4] = rx_led != 0;
assign led[5] = tx_led != 0;
assign led[6] = icmp_led != 0;
assign led[7] = rxc_freq != 0;

endmodule

`resetall
