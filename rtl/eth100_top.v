/*
 * eth100_top.v — 100 Mb/s RGMII Ethernet for ULX5M-GS (GateMate CCGM1A1 + KSZ9031RNX)
 *
 * Carries over what made the LiteX design on the same board ping
 * (litex-eth-ulx5m-gs, tag eth100-ping-ok-20260924, profile x1):
 *
 *  Clock   : 25 MHz IO_SB_A8 is the logic clock (stack, MDIO, UART) and the PLL reference;
 *            CC_PLL (ECONOMY) -> 50 MHz CLK0 (eth_tx: MAC TX + TX pads) and CLK180 (TXC).
 *            Only the MAC TX runs on 50 MHz, like the LiteX design (sys 16 MHz, eth_tx 50 MHz):
 *            with the whole stack on 50 MHz the routed clk50 closed at 40..47 MHz only.
 *            The PHY's XI comes from the on-board X1 oscillator; IO_EB_A3 is NOT driven
 *            (on the boards with X1 the trace to E16 is cut).
 *  TX      : "io50". KSZ9031 adds no delay on its TX inputs and at 100M TX_CTL is sampled
 *            on both TXC edges, so TXC must sit 90 deg off the data. TXD/TX_CTL are posedge
 *            IOSEL flip-flops on clk50 that change every 2nd cycle (MAC clock enable =
 *            tx_phase); TXC is an IOSEL flip-flop on CLK180 that samples tx_phase. TXC rises
 *            10 ns after the data changes and falls 10 ns before the next change.
 *            (A CLK90 net routed to the pad through fabric took 6..7 ns and moved with the
 *            seed; negedge IOSEL FFs lose CLK_INV in nextpnr, hence CLK180.)
 *  RX      : RXC (IO_EB_A7, 25 MHz at 100M) clocks CC_IDDR; at 100M both halves carry the
 *            same nibble, the rising-edge half (Q0) is used.
 *  MDIO    : CC_IOBUF with a registered, non-constant T; PHYAD 3; 100FD-only advert.
 *  Reset   : RESET_N held low ~42 ms after configuration (KSZ9031 tSR >= 10 ms), counted on
 *            clk and released by CC_USR_RSTN only, so a PLL glitch cannot re-reset the PHY.
 *  UART    : TX IO_NB_B5 / RX IO_NA_B6 (DirtyJTAG bridge), 115200 8N1, one status line/s.
 *
 * LEDs: 0 heartbeat, 1 MDIO ID ok, 2 link up, 3 100FD, 4 RX frame, 5 TX frame, 6 ICMP, 7 RXC alive
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module eth100_top #(
    // Simulation shortens these; the defaults are the hardware values.
    parameter        PHY_RST_BIT  = 20,                 // RESET_N low for 2^20 clk25 = 42 ms
    parameter [23:0] MDIO_SETTLE  = 24'd2_500_000,      // 100 ms before the first MDIO access
    parameter [23:0] MDIO_POLL    = 24'd1_250_000,      // 50 ms between MDIO poll rounds
    parameter [25:0] STATUS_TICKS = 26'd24_999_999      // one UART status line per second
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
wire clk50, clk50_180;
wire pll_locked, pll_locked_stdy;

CC_PLL #(
    .REF_CLK("25.0"),
    .OUT_CLK("50.0"),
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
    .CLK0(clk50),
    .CLK90(),
    .CLK180(clk50_180),
    .CLK270(),
    .CLK_REF_OUT()
);

wire usr_rstn;
CC_USR_RSTN usr_rstn_inst (.USR_RSTN(usr_rstn));

// Logic clock: the 25 MHz pad (nextpnr puts it on a global, any pin can be a clock).
wire clk = clk_25mhz;

// ------------------------------------------------------------------ resets (clk)
// PHY reset: 2^20 / 25 MHz = 42 ms, only CC_USR_RSTN restarts it.
reg [PHY_RST_BIT:0] phy_rst_cnt = 0;
always @(posedge clk) begin
    if (!usr_rstn)
        phy_rst_cnt <= 0;
    else if (!phy_rst_cnt[PHY_RST_BIT])
        phy_rst_cnt <= phy_rst_cnt + 1'b1;
end
wire phy_out_of_reset = phy_rst_cnt[PHY_RST_BIT];
assign eth_rst_n = phy_out_of_reset;

// Logic reset: released 2.6 ms after configuration (the PLL locks well before).
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

// eth_tx domain reset: synchronised copy of rst
(* keep *) reg tx_rst_s0 = 1'b1;
(* keep *) reg tx_rst    = 1'b1;
always @(posedge clk50 or posedge rst) begin
    if (rst) begin
        tx_rst_s0 <= 1'b1;
        tx_rst    <= 1'b1;
    end else begin
        tx_rst_s0 <= 1'b0;
        tx_rst    <= tx_rst_s0;
    end
end

// RX domain reset: synchronised copy of rst
(* keep *) reg rx_rst_s0 = 1'b1;
(* keep *) reg rx_rst    = 1'b1;
always @(posedge eth_rx_clk or posedge rst) begin
    if (rst) begin
        rx_rst_s0 <= 1'b1;
        rx_rst    <= 1'b1;
    end else begin
        rx_rst_s0 <= 1'b0;
        rx_rst    <= rx_rst_s0;
    end
end

// ------------------------------------------------------------------ RGMII TX (io50)
reg tx_phase = 1'b0;
always @(posedge clk50)
    tx_phase <= ~tx_phase;

wire [7:0] gmii_txd;
wire       gmii_tx_en, gmii_tx_er;

reg [3:0] txd_io;
reg       txctl_io;
reg       txc_io;
always @(posedge clk50) begin
    txd_io   <= gmii_txd[3:0];
    txctl_io <= gmii_tx_en;
end
always @(posedge clk50_180)
    txc_io <= tx_phase;

assign eth_txd    = txd_io;
assign eth_tx_ctl = txctl_io;
assign eth_tx_clk = txc_io;

// ------------------------------------------------------------------ RGMII RX
wire [3:0] rxd_q0, rxd_q1;
wire       rxctl_q0, rxctl_q1;

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : g_rx
        CC_IDDR rxd_iddr (.D(eth_rxd[i]), .CLK(eth_rx_clk), .Q0(rxd_q0[i]), .Q1(rxd_q1[i]));
    end
endgenerate
CC_IDDR rxctl_iddr (.D(eth_rx_ctl), .CLK(eth_rx_clk), .Q0(rxctl_q0), .Q1(rxctl_q1));

reg [3:0] rx_nib;
reg       rx_dv;
always @(posedge eth_rx_clk) begin
    rx_nib <= rxd_q0;
    rx_dv  <= rxctl_q0;
end

// ------------------------------------------------------------------ MAC + stack
wire [15:0] rx_frames, rx_bad, tx_frames, icmp_count, udp_count;

eth_core #(
    .MII_SELECT(1)
) core_inst (
    .clk(clk),
    .rst(rst),
    .tx_clk(clk50),
    .tx_rst(tx_rst),
    .rx_clk(eth_rx_clk),
    .rx_rst(rx_rst),
    .gmii_rxd({4'd0, rx_nib}),
    .gmii_rx_dv(rx_dv),
    .gmii_rx_er(1'b0),
    .gmii_txd(gmii_txd),
    .gmii_tx_en(gmii_tx_en),
    .gmii_tx_er(gmii_tx_er),
    .tx_clk_enable(tx_phase),
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
    .G1000(0)
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
always @(posedge eth_rx_clk)
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
            rxc_freq  <= rxc_edges;   // half-periods of rxc/1024 = edges/512 -> /2 below
            rxc_edges <= 20'd0;
            tick_1s   <= 1'b1;
        end else begin
            sec_cnt <= sec_cnt + 26'd1;
        end
    end
end

// ------------------------------------------------------------------ UART status
uart_status #(
    .CLK_HZ(25_000_000),
    .BAUD(115_200)
) status_inst (
    .clk(clk),
    .rst(rst),
    .trigger(tick_1s),
    .id1_i(id1), .id2_i(id2), .bmsr_i(bmsr), .phyctl_i(phyctl),
    .rxcf_i({1'b0, rxc_freq[19:1]}),
    .rxf_i(rx_frames), .bad_i(rx_bad), .txf_i(tx_frames),
    .icmp_i(icmp_count), .udp_i(udp_count),
    .tries_i(mdio_tries),
    .txd(uart_tx)
);
assign uart_tx_alt = uart_tx;

// ------------------------------------------------------------------ LEDs (active high)
reg [15:0] rx_last, tx_last, icmp_last;
reg [20:0] rx_led, tx_led, icmp_led;
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
assign led[3] = (phyctl[6:3] == 4'b0101);   // reg 0x1F: bit5=100M, bit3=FD
assign led[4] = rx_led != 0;
assign led[5] = tx_led != 0;
assign led[6] = icmp_led != 0;
assign led[7] = rxc_freq != 0;

endmodule

`resetall
