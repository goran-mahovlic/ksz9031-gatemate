/*
 * FPGA top-level module — GateMate CCGM1A1 (ULX5M-GS)
 * Ported from Spartan-6 KSZ9031 GbE design
 *
 * Architecture:
 *   CC_PLL: 25 MHz → 125 MHz (0°) + 125 MHz (90°)
 *   gatemate_rgmii_if: RGMII pads ↔ GMII signals (GateMate CC_ODDR/CC_IDDR)
 *   fpga_core: eth_mac_1g_fifo (GMII MAC) + UDP/IP/ARP + UART + MDIO
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module fpga (
    // Clock: 25 MHz oscillator
    input  wire        clk_25mhz,

    // GPIO
    input  wire [2:0]  btn,
    output wire [7:0]  led,

    // UART
    output wire        uart_tx,
    input  wire        uart_rx,

    // Ethernet: 1000BASE-T RGMII (KSZ9031)
    output wire        eth_tx_clk,
    output wire [3:0]  eth_txd,
    output wire        eth_tx_ctl,
    input  wire        eth_rx_clk,
    input  wire [3:0]  eth_rxd,
    input  wire        eth_rx_ctl,
    output wire        eth_rst_n,
    output wire        eth_mdc,
    inout  wire        eth_mdio
);

// ============================================================
// Clock Generation — CC_PLL: 25 MHz → 125 MHz + 90°
// ============================================================
wire clk_125;
wire clk_125_90;
wire pll_locked;
wire clk_25;

/* PLL: 25MHz (pix clock) and 125MHz (hdmi clk rate) */
wire clk_pix, clk_dvi, lock;
pll pll_inst (
	.clock_in(clk_25mhz),       //  50 MHz reference
	.clock_out(clk_25),    //  25 MHz, 0 deg
	.clock_5x_out(clk_125), // 125 MHz, 0 deg
	.clock_5x_90_out(clk_125_90),
	.lock_out(pll_locked)
);

reg [31:0] blink_counter;

always @(posedge clk_125) begin
    if (~rst_int)
        blink_counter <= 32'd0;
    else
        blink_counter <= blink_counter + 1'b1;
end

assign led[0] = blink_counter;

// ============================================================
// Reset — device user reset + PLL lock
// ============================================================
wire usr_rst_n;

CC_USR_RSTN usr_rstn_inst (
    .USR_RSTN(usr_rst_n)
);

// Synchronous reset generation
reg [3:0] rst_cnt = 4'hF;
reg rst_int = 1'b1;

always @(posedge clk_125) begin
    if (!pll_locked || !btn[2]) begin
        rst_cnt <= 4'hF;
        rst_int <= 1'b1;
    end else if (rst_cnt != 0) begin
        rst_cnt <= rst_cnt - 1;
        rst_int <= 1'b1;
    end else begin
        rst_int <= 1'b0;
    end
end

// PHY reset — hold for ~33ms after system reset release
// 22-bit counter at 125 MHz: 2^22 / 125e6 ≈ 33.6 ms
reg [21:0] phy_rst_cnt = 22'h3FFFFF;
reg phy_rst_n_reg = 1'b0;

always @(posedge clk_125) begin
    if (rst_int) begin
        phy_rst_cnt <= 22'h3FFFFF;
        phy_rst_n_reg <= 1'b0;
    end else if (phy_rst_cnt != 0) begin
        phy_rst_cnt <= phy_rst_cnt - 1;
        phy_rst_n_reg <= 1'b0;
    end else begin
        phy_rst_n_reg <= 1'b1;
    end
end

assign eth_rst_n = phy_rst_n_reg;

// ============================================================
// GPIO — debounce (2 buttons, no DIP switches on ULX5M)
// ============================================================
wire [1:0] btn_int;

debounce_switch #(
    .WIDTH(2),
    .N(4),
    .RATE(125000)
) debounce_switch_inst (
    .clk(clk_125),
    .rst(rst_int),
    .in(btn[1:0]),
    .out(btn_int)
);

// Debug LEDs driven by fpga_core (active-high: 1 = ON)
// See fpga_core.v for LED[0..7] assignments

// ============================================================
// RGMII ↔ GMII conversion (GateMate CC_ODDR/CC_IDDR)
// ============================================================
wire [7:0] gmii_rxd;
wire       gmii_rx_dv;
wire       gmii_rx_er;
wire [7:0] gmii_txd;
wire       gmii_tx_en;
wire       gmii_tx_er;
wire       rgmii_rx_clk_int;
wire       rgmii_tx_clk_int;

gatemate_rgmii_if rgmii_if_inst (
    .clk_125(clk_125),
    .clk_125_90(clk_125_90),
    .rst(rst_int),

    // GMII side (to/from MAC)
    .mac_gmii_rxd(gmii_rxd),
    .mac_gmii_rx_dv(gmii_rx_dv),
    .mac_gmii_rx_er(gmii_rx_er),
    .mac_gmii_txd(gmii_txd),
    .mac_gmii_tx_en(gmii_tx_en),
    .mac_gmii_tx_er(gmii_tx_er),

    // RGMII side (to/from PHY pads)
    .phy_rgmii_rx_clk(eth_rx_clk),
    .phy_rgmii_rxd(eth_rxd),
    .phy_rgmii_rx_ctl(eth_rx_ctl),
    .phy_rgmii_tx_clk(eth_tx_clk),
    .phy_rgmii_txd(eth_txd),
    .phy_rgmii_tx_ctl(eth_tx_ctl),

    // Clock outputs
    .rx_clk(rgmii_rx_clk_int),
    .tx_clk(rgmii_tx_clk_int),
    .speed()
);

// ============================================================
// Core Logic (GMII MAC + UDP/IP/ARP + UART + MDIO)
// ============================================================
fpga_core core_inst (
    .clk(clk_125),
    .rst(rst_int),

    // GPIO
    .push(btn_int),
    .sw(8'hFF),
    //.led(led),

    // PHY control
    .MDC(eth_mdc),
    .MDIO(eth_mdio),
    //.V3_3(1'b1),
    //.CLK_125MHZ(clk_125),

    // UART
    .txd(uart_tx),
    .rxd(uart_rx),

    // GMII interface (from gatemate_rgmii_if)
    .gmii_rx_clk(rgmii_rx_clk_int),
    .gmii_rxd(gmii_rxd),
    .gmii_rx_dv(gmii_rx_dv),
    .gmii_rx_er(gmii_rx_er),
    .gmii_txd(gmii_txd),
    .gmii_tx_en(gmii_tx_en),
    .gmii_tx_er(gmii_tx_er),

    // PHY reset (eth_rst_n driven by top-level timer, ignore core output)
    .phy0_reset_n(/* unused — overridden by phy_rst_n_reg */),
    .phy0_int_n(1'b1)
);

endmodule

`resetall
