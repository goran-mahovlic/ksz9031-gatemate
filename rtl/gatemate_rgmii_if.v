/*
 * GateMate RGMII PHY Interface
 * Replaces Forencich rgmii_phy_if.v + iddr.v + oddr.v + ssio_ddr_*.v
 * Uses native GateMate primitives: CC_ODDR, CC_IDDR, CC_OBUF, CC_IBUF, CC_IOBUF
 *
 * Reference: LiteX gatematergmii.py, GateMate FPGA Primitives Library
 *
 * TX: data registered → CC_ODDR → CC_OBUF (SLEW=fast)
 *     clk_125_90 → CC_ODDR(0,1) → CC_OBUF = TX clock (90° shifted)
 * RX: CC_IBUF → CC_IDDR on source-synchronous rx_clk domain
 *
 * CRITICAL: CC_IOBUF T polarity is INVERTED vs Xilinx!
 *   GateMate: T=0 → output, T=1 → hi-Z
 *   Xilinx:   T=0 → hi-Z,   T=1 → output
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gatemate_rgmii_if (
    input  wire        clk_125,        // 125 MHz, 0° phase (data clock)
    input  wire        clk_125_90,     // 125 MHz, 90° phase (TX clock output)
    input  wire        rst,

    // GMII interface (to/from MAC)
    output wire [7:0]  mac_gmii_rxd,
    output wire        mac_gmii_rx_dv,
    output wire        mac_gmii_rx_er,
    input  wire [7:0]  mac_gmii_txd,
    input  wire        mac_gmii_tx_en,
    input  wire        mac_gmii_tx_er,

    // RGMII interface (to/from PHY pads)
    input  wire        phy_rgmii_rx_clk,
    input  wire [3:0]  phy_rgmii_rxd,
    input  wire        phy_rgmii_rx_ctl,
    output wire        phy_rgmii_tx_clk,
    output wire [3:0]  phy_rgmii_txd,
    output wire        phy_rgmii_tx_ctl,

    // Clock outputs
    output wire        rx_clk,         // Source-synchronous RX clock domain
    output wire        tx_clk,         // TX clock = clk_125

    // Speed (fixed at 1000)
    output wire [1:0]  speed
);

// Speed always 1000 Mbps
assign speed = 2'b10;
assign rx_clk = phy_rgmii_rx_clk;
assign tx_clk = clk_125;

// ============================================================
// TX Path: GMII → RGMII DDR
// ============================================================

// Register TX data for timing (1 cycle pipeline, same as LiteX)
reg [3:0] tx_data_h;   // bits [3:0] on rising edge
reg [3:0] tx_data_l;   // bits [7:4] on falling edge
reg       tx_ctl_h;    // tx_en on rising edge
reg       tx_ctl_l;    // tx_en XOR tx_er on falling edge (RGMII spec)

always @(posedge clk_125) begin
    tx_data_h <= mac_gmii_txd[3:0];
    tx_data_l <= mac_gmii_txd[7:4];
    tx_ctl_h  <= mac_gmii_tx_en;
    tx_ctl_l  <= mac_gmii_tx_en ^ mac_gmii_tx_er;
end

// TX Data [3:0] — CC_ODDR + CC_OBUF
wire [3:0] tx_data_ddr;

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : gen_tx_data
        CC_ODDR #(
            .CLK_INV(0)
        ) tx_data_oddr (
            .D0(tx_data_h[i]),
            .D1(tx_data_l[i]),
            .CLK(clk_125),
            .DDR(clk_125),
            .Q(tx_data_ddr[i])
        );

        CC_OBUF #(
            .DELAY_OBF(0),
            .SLEW("FAST")
        ) tx_data_obuf (
            .A(tx_data_ddr[i]),
            .O(phy_rgmii_txd[i])
        );
    end
endgenerate

// TX Control — CC_ODDR + CC_OBUF
wire tx_ctl_ddr;

CC_ODDR #(
    .CLK_INV(0)
) tx_ctl_oddr (
    .D0(tx_ctl_h),
    .D1(tx_ctl_l),
    .CLK(clk_125),
    .DDR(clk_125),
    .Q(tx_ctl_ddr)
);

CC_OBUF #(
    .DELAY_OBF(0),
    .SLEW("FAST")
) tx_ctl_obuf (
    .A(tx_ctl_ddr),
    .O(phy_rgmii_tx_ctl)
);

// TX Clock — 90° shifted from PLL → CC_OBUF directly.
// CC_ODDR is not used here: D0=0/D1=1 through ODDR is equivalent to passing
// the clock through, but ODDR requires same DDR-clock as data pins in the
// same IO bank (WA_B3). Since data uses clk_125 and clock needs clk_125_90,
// using ODDR here causes a bank DDR-source conflict in nextpnr-himbaechel.
// The 90° PLL output is already 50% duty-cycle, so CC_OBUF is sufficient.

CC_OBUF #(
    .DELAY_OBF(0),
    .SLEW("FAST")
) tx_clk_obuf (
    .A(clk_125_90),
    .O(phy_rgmii_tx_clk)
);

// ============================================================
// RX Path: RGMII DDR → GMII
// ============================================================

// RX Data [3:0] — CC_IBUF + CC_IDDR
wire [3:0] rx_data_buf;
wire [3:0] rx_data_rise;  // bits [3:0] captured on rising edge
wire [3:0] rx_data_fall;  // bits [7:4] captured on falling edge

generate
    for (i = 0; i < 4; i = i + 1) begin : gen_rx_data
        CC_IBUF #(
            .DELAY_IBF(0)
        ) rx_data_ibuf (
            .I(phy_rgmii_rxd[i]),
            .Y(rx_data_buf[i])
        );

        CC_IDDR rx_data_iddr (
            .D(rx_data_buf[i]),
            .CLK(phy_rgmii_rx_clk),
            .Q0(rx_data_rise[i]),
            .Q1(rx_data_fall[i])
        );
    end
endgenerate

// RX Control — CC_IBUF + CC_IDDR
wire rx_ctl_buf;
wire rx_ctl_rise;  // rx_dv on rising edge
wire rx_ctl_fall;  // rx_dv XOR rx_er on falling edge

CC_IBUF #(
    .DELAY_IBF(0)
) rx_ctl_ibuf (
    .I(phy_rgmii_rx_ctl),
    .Y(rx_ctl_buf)
);

CC_IDDR rx_ctl_iddr (
    .D(rx_ctl_buf),
    .CLK(phy_rgmii_rx_clk),
    .Q0(rx_ctl_rise),
    .Q1(rx_ctl_fall)
);

// Re-register RX data in rx_clk domain for clean output
reg [3:0] rx_data_lsb_r;
reg [3:0] rx_data_msb_r;
reg       rx_dv_r;
reg       rx_er_r;

always @(posedge phy_rgmii_rx_clk) begin
    rx_data_lsb_r <= rx_data_rise;
    rx_data_msb_r <= rx_data_fall;
    rx_dv_r       <= rx_ctl_rise;
    rx_er_r       <= rx_ctl_rise ^ rx_ctl_fall;  // RGMII: ctl_fall = dv XOR er
end

assign mac_gmii_rxd   = {rx_data_msb_r, rx_data_lsb_r};
assign mac_gmii_rx_dv = rx_dv_r;
assign mac_gmii_rx_er = rx_er_r;

endmodule

`resetall
