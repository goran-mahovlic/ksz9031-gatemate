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
    output wire [3:0]  led,

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

CC_PLL #(
    .REF_CLK("25.0"),
    .OUT_CLK("125.0"),
    .PERF_MD("SPEED"),
    .LOW_JITTER(1),
    .CI_FILTER_CONST(2),
    .CP_FILTER_CONST(4)
) pll_inst (
    .CLK_REF(clk_25mhz),
    .CLK_FEEDBACK(1'b0),
    .USR_CLK_REF(1'b0),
    .USR_LOCKED_STDY_RST(1'b0),
    //.USR_SET_SEL(1'b0),
    .CLK0(clk_125),
    .CLK90(clk_125_90),
    .CLK180(),
    .CLK270(),
    .CLK_REF_OUT(),
    .USR_PLL_LOCKED_STDY(pll_locked),
    .USR_PLL_LOCKED()
);

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
    if (!pll_locked || !usr_rst_n || !btn[2]) begin
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

// Debug LEDs (active-low: 0 = ON, 1 = OFF)
// LED[0]: ON when system running (rst_int=0 after PLL lock)
// LED[1]: ON when PHY out of reset (phy_rst_n_reg=1)
// LED[2]: Blinks ON during RX activity (gmii_rx_dv=1)
// LED[3]: Blinks ON during TX activity (gmii_tx_en=1)
assign led[0] = rst_int;            // active-low: rst_int=0 → LED ON
assign led[1] = ~phy_rst_n_reg;     // active-low: phy_rst_n_reg=1 → LED ON
assign led[2] = ~gmii_rx_dv;        // active-low: gmii_rx_dv=1 → LED ON
assign led[3] = ~gmii_tx_en;        // active-low: gmii_tx_en=1 → LED ON

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
    //.led(led_int),

    // PHY control
    .MDC(eth_mdc),
    .MDIO(eth_mdio),
    .V3_3(1'b1),
    .CLK_125MHZ(clk_125),

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
