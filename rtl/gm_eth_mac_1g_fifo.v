/*
 * GateMate-optimized 1G Ethernet MAC with TX and RX FIFOs
 *
 * Drop-in replacement for Forencich eth_mac_1g_fifo.
 * - TX path: gm_sync_fifo (logic_clk == tx_clk, no CDC needed)
 * - RX path: gm_async_fifo (rx_clk != logic_clk, Gray-code CDC)
 * - No frame FIFO logic (FRAME_FIFO params kept for interface compat, ignored)
 * - Max 3 LUT levels in critical path (vs 8-20 in original)
 *
 * DATA_WIDTH=10 packing: {tuser[0], tlast, tdata[7:0]}
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gm_eth_mac_1g_fifo #(
    parameter AXIS_DATA_WIDTH     = 8,
    parameter AXIS_KEEP_ENABLE    = (AXIS_DATA_WIDTH>8),
    parameter AXIS_KEEP_WIDTH     = (AXIS_DATA_WIDTH/8),
    parameter ENABLE_PADDING      = 1,
    parameter MIN_FRAME_LENGTH    = 64,
    parameter TX_FIFO_DEPTH       = 64,
    parameter TX_FIFO_RAM_PIPELINE = 1,  // ignored, kept for compatibility
    parameter TX_FRAME_FIFO       = 1,   // ignored, kept for compatibility
    parameter TX_DROP_OVERSIZE_FRAME = 0, // ignored
    parameter TX_DROP_BAD_FRAME   = 0,   // ignored
    parameter TX_DROP_WHEN_FULL   = 0,   // ignored
    parameter RX_FIFO_DEPTH       = 64,
    parameter RX_FIFO_RAM_PIPELINE = 1,  // ignored
    parameter RX_FRAME_FIFO       = 1,   // ignored
    parameter RX_DROP_OVERSIZE_FRAME = 0, // ignored
    parameter RX_DROP_BAD_FRAME   = 0,   // ignored
    parameter RX_DROP_WHEN_FULL   = 0    // ignored
)(
    input  wire                       rx_clk,
    input  wire                       rx_rst,
    input  wire                       tx_clk,
    input  wire                       tx_rst,
    input  wire                       logic_clk,
    input  wire                       logic_rst,

    /*
     * AXI input (TX from user logic, logic_clk domain)
     */
    input  wire [AXIS_DATA_WIDTH-1:0] tx_axis_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0] tx_axis_tkeep,
    input  wire                       tx_axis_tvalid,
    output wire                       tx_axis_tready,
    input  wire                       tx_axis_tlast,
    input  wire                       tx_axis_tuser,

    /*
     * AXI output (RX to user logic, logic_clk domain)
     */
    output wire [AXIS_DATA_WIDTH-1:0] rx_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0] rx_axis_tkeep,
    output wire                       rx_axis_tvalid,
    input  wire                       rx_axis_tready,
    output wire                       rx_axis_tlast,
    output wire                       rx_axis_tuser,

    /*
     * GMII interface
     */
    input  wire [7:0]                 gmii_rxd,
    input  wire                       gmii_rx_dv,
    input  wire                       gmii_rx_er,
    output wire [7:0]                 gmii_txd,
    output wire                       gmii_tx_en,
    output wire                       gmii_tx_er,

    /*
     * Control
     */
    input  wire                       rx_clk_enable,
    input  wire                       tx_clk_enable,
    input  wire                       rx_mii_select,
    input  wire                       tx_mii_select,

    /*
     * Status
     */
    output wire                       tx_error_underflow,
    output wire                       tx_fifo_overflow,
    output wire                       tx_fifo_bad_frame,
    output wire                       tx_fifo_good_frame,
    output wire                       rx_error_bad_frame,
    output wire                       rx_error_bad_fcs,
    output wire                       rx_fifo_overflow,
    output wire                       rx_fifo_bad_frame,
    output wire                       rx_fifo_good_frame,

    /*
     * Configuration
     */
    input  wire [7:0]                 cfg_ifg,
    input  wire                       cfg_tx_enable,
    input  wire                       cfg_rx_enable
);

// ====================================================================
// Internal wires: MAC <-> FIFOs
// ====================================================================
wire [7:0] tx_fifo_axis_tdata;
wire       tx_fifo_axis_tvalid;
wire       tx_fifo_axis_tready;
wire       tx_fifo_axis_tlast;
wire       tx_fifo_axis_tuser;

wire [7:0] rx_fifo_axis_tdata;
wire       rx_fifo_axis_tvalid;
wire       rx_fifo_axis_tlast;
wire       rx_fifo_axis_tuser;

// ====================================================================
// Status: sync tx_error_underflow from tx_clk to logic_clk
// (toggle-based pulse synchronizer, copied from original)
// ====================================================================
wire tx_error_underflow_int;

reg [0:0] tx_sync_reg_1 = 1'b0;
reg [0:0] tx_sync_reg_2 = 1'b0;
reg [0:0] tx_sync_reg_3 = 1'b0;
reg [0:0] tx_sync_reg_4 = 1'b0;

assign tx_error_underflow = tx_sync_reg_3[0] ^ tx_sync_reg_4[0];

always @(posedge tx_clk or posedge tx_rst) begin
    if (tx_rst)
        tx_sync_reg_1 <= 1'b0;
    else
        tx_sync_reg_1 <= tx_sync_reg_1 ^ {tx_error_underflow_int};
end

always @(posedge logic_clk or posedge logic_rst) begin
    if (logic_rst) begin
        tx_sync_reg_2 <= 1'b0;
        tx_sync_reg_3 <= 1'b0;
        tx_sync_reg_4 <= 1'b0;
    end else begin
        tx_sync_reg_2 <= tx_sync_reg_1;
        tx_sync_reg_3 <= tx_sync_reg_2;
        tx_sync_reg_4 <= tx_sync_reg_3;
    end
end

// ====================================================================
// Status: sync rx_error_bad_frame/bad_fcs from rx_clk to logic_clk
// ====================================================================
wire rx_error_bad_frame_int;
wire rx_error_bad_fcs_int;

reg [1:0] rx_sync_reg_1 = 2'd0;
reg [1:0] rx_sync_reg_2 = 2'd0;
reg [1:0] rx_sync_reg_3 = 2'd0;
reg [1:0] rx_sync_reg_4 = 2'd0;

assign rx_error_bad_frame = rx_sync_reg_3[0] ^ rx_sync_reg_4[0];
assign rx_error_bad_fcs   = rx_sync_reg_3[1] ^ rx_sync_reg_4[1];

always @(posedge rx_clk or posedge rx_rst) begin
    if (rx_rst)
        rx_sync_reg_1 <= 2'd0;
    else
        rx_sync_reg_1 <= rx_sync_reg_1 ^ {rx_error_bad_fcs_int, rx_error_bad_frame_int};
end

always @(posedge logic_clk or posedge logic_rst) begin
    if (logic_rst) begin
        rx_sync_reg_2 <= 2'd0;
        rx_sync_reg_3 <= 2'd0;
        rx_sync_reg_4 <= 2'd0;
    end else begin
        rx_sync_reg_2 <= rx_sync_reg_1;
        rx_sync_reg_3 <= rx_sync_reg_2;
        rx_sync_reg_4 <= rx_sync_reg_3;
    end
end

// ====================================================================
// Frame tracking status: not supported in minimal design
// ====================================================================
assign tx_fifo_overflow   = 1'b0;
assign tx_fifo_bad_frame  = 1'b0;
assign tx_fifo_good_frame = 1'b0;
assign rx_fifo_overflow   = 1'b0;
assign rx_fifo_bad_frame  = 1'b0;
assign rx_fifo_good_frame = 1'b0;

// ====================================================================
// Keep output (8-bit data width: keep is always 1)
// ====================================================================
assign rx_axis_tkeep = {AXIS_KEEP_WIDTH{1'b1}};

// ====================================================================
// eth_mac_1g instance (from lib/eth — NOT modified)
// ====================================================================
eth_mac_1g #(
    .ENABLE_PADDING(ENABLE_PADDING),
    .MIN_FRAME_LENGTH(MIN_FRAME_LENGTH)
)
eth_mac_1g_inst (
    .tx_clk(tx_clk),
    .tx_rst(tx_rst),
    .rx_clk(rx_clk),
    .rx_rst(rx_rst),
    .tx_axis_tdata(tx_fifo_axis_tdata),
    .tx_axis_tvalid(tx_fifo_axis_tvalid),
    .tx_axis_tready(tx_fifo_axis_tready),
    .tx_axis_tlast(tx_fifo_axis_tlast),
    .tx_axis_tuser(tx_fifo_axis_tuser),
    .rx_axis_tdata(rx_fifo_axis_tdata),
    .rx_axis_tvalid(rx_fifo_axis_tvalid),
    .rx_axis_tlast(rx_fifo_axis_tlast),
    .rx_axis_tuser(rx_fifo_axis_tuser),
    .gmii_rxd(gmii_rxd),
    .gmii_rx_dv(gmii_rx_dv),
    .gmii_rx_er(gmii_rx_er),
    .gmii_txd(gmii_txd),
    .gmii_tx_en(gmii_tx_en),
    .gmii_tx_er(gmii_tx_er),
    .rx_clk_enable(rx_clk_enable),
    .tx_clk_enable(tx_clk_enable),
    .rx_mii_select(rx_mii_select),
    .tx_mii_select(tx_mii_select),
    .tx_error_underflow(tx_error_underflow_int),
    .rx_error_bad_frame(rx_error_bad_frame_int),
    .rx_error_bad_fcs(rx_error_bad_fcs_int),
    .cfg_ifg(cfg_ifg),
    .cfg_tx_enable(cfg_tx_enable),
    .cfg_rx_enable(cfg_rx_enable)
);

// ====================================================================
// TX FIFO: Sync FIFO (logic_clk == tx_clk, same domain)
// Pack: {tuser, tlast, tdata[7:0]} = 10 bits
// ====================================================================
wire        tx_fifo_full;
wire        tx_fifo_empty;
wire [9:0]  tx_fifo_rd_data;

// Write side: user logic pushes into FIFO
assign tx_axis_tready = ~tx_fifo_full;

// Read side: MAC pulls from FIFO
// BRAM has 1-cycle read latency, so we track valid with a pipeline register
wire tx_fifo_rd_en = (~tx_fifo_axis_tvalid_reg | tx_fifo_axis_tready) & ~tx_fifo_empty;

reg tx_fifo_axis_tvalid_reg = 1'b0;
always @(posedge logic_clk) begin
    if (logic_rst)
        tx_fifo_axis_tvalid_reg <= 1'b0;
    else if (tx_fifo_rd_en)
        tx_fifo_axis_tvalid_reg <= 1'b1;
    else if (tx_fifo_axis_tready)
        tx_fifo_axis_tvalid_reg <= 1'b0;
end

assign tx_fifo_axis_tdata  = tx_fifo_rd_data[7:0];
assign tx_fifo_axis_tlast  = tx_fifo_rd_data[8];
assign tx_fifo_axis_tuser  = tx_fifo_rd_data[9];
assign tx_fifo_axis_tvalid = tx_fifo_axis_tvalid_reg;

gm_sync_fifo #(
    .DEPTH(TX_FIFO_DEPTH),
    .DATA_WIDTH(10)
)
tx_fifo (
    .clk(logic_clk),
    .rst(logic_rst),
    .wr_data({tx_axis_tuser, tx_axis_tlast, tx_axis_tdata[7:0]}),
    .wr_en(tx_axis_tvalid & tx_axis_tready),
    .full(tx_fifo_full),
    .rd_data(tx_fifo_rd_data),
    .rd_en(tx_fifo_rd_en),
    .empty(tx_fifo_empty)
);

// ====================================================================
// RX FIFO: Async FIFO (rx_clk -> logic_clk CDC)
// Pack: {tuser, tlast, tdata[7:0]} = 10 bits
// ====================================================================
wire        rx_fifo_wr_full;
wire        rx_fifo_rd_empty;
wire [9:0]  rx_fifo_rd_data;

// Write side: MAC pushes into FIFO (rx_clk domain)
// No backpressure from FIFO to MAC — MAC always produces valid data.
// If FIFO is full, data is silently dropped (minimal design).

// Read side: user logic pulls from FIFO (logic_clk domain)
// BRAM has 1-cycle read latency, so we track valid with a pipeline register
wire rx_fifo_rd_en = (~rx_axis_tvalid_reg | rx_axis_tready) & ~rx_fifo_rd_empty;

reg rx_axis_tvalid_reg = 1'b0;
always @(posedge logic_clk) begin
    if (logic_rst)
        rx_axis_tvalid_reg <= 1'b0;
    else if (rx_fifo_rd_en)
        rx_axis_tvalid_reg <= 1'b1;
    else if (rx_axis_tready)
        rx_axis_tvalid_reg <= 1'b0;
end

assign rx_axis_tdata  = rx_fifo_rd_data[7:0];
assign rx_axis_tlast  = rx_fifo_rd_data[8];
assign rx_axis_tuser  = rx_fifo_rd_data[9];
assign rx_axis_tvalid = rx_axis_tvalid_reg;

gm_async_fifo #(
    .DEPTH(RX_FIFO_DEPTH),
    .DATA_WIDTH(10)
)
rx_fifo (
    // Write side (rx_clk domain)
    .wr_clk(rx_clk),
    .wr_rst(rx_rst),
    .wr_data({rx_fifo_axis_tuser, rx_fifo_axis_tlast, rx_fifo_axis_tdata[7:0]}),
    .wr_en(rx_fifo_axis_tvalid & ~rx_fifo_wr_full),
    .wr_full(rx_fifo_wr_full),
    // Read side (logic_clk domain)
    .rd_clk(logic_clk),
    .rd_rst(logic_rst),
    .rd_data(rx_fifo_rd_data),
    .rd_en(rx_fifo_rd_en),
    .rd_empty(rx_fifo_rd_empty)
);

endmodule

`resetall
