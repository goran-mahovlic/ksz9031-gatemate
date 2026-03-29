/*
 * GateMate-optimized asynchronous FIFO for CDC
 * - Gray code pointer crossing with 2-FF synchronizers
 * - Pipelined (registered) full/empty flags: max 3 LUT levels in critical path
 * - reg array storage (Yosys maps to CC_BRAM automatically)
 *
 * Used for RX path where rx_clk (eth_rx_clk) != logic_clk (clk_125).
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gm_async_fifo #(
    parameter DEPTH      = 64,
    parameter DATA_WIDTH = 10   // 8 data + 1 last + 1 user
)(
    // Write side (rx_clk domain)
    input  wire                  wr_clk,
    input  wire                  wr_rst,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    output reg                   wr_full,

    // Read side (logic_clk domain)
    input  wire                  rd_clk,
    input  wire                  rd_rst,
    output wire [DATA_WIDTH-1:0] rd_data,
    input  wire                  rd_en,
    output reg                   rd_empty
);

localparam ADDR_W = $clog2(DEPTH);

// -----------------------------------------------------------
// Memory
// -----------------------------------------------------------
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

// -----------------------------------------------------------
// Write-side binary & Gray pointers
// -----------------------------------------------------------
reg [ADDR_W:0] wr_ptr = {(ADDR_W+1){1'b0}};

wire wr_valid = wr_en & ~wr_full;

always @(posedge wr_clk) begin
    if (wr_rst)
        wr_ptr <= {(ADDR_W+1){1'b0}};
    else if (wr_valid)
        wr_ptr <= wr_ptr + 1'b1;
end

always @(posedge wr_clk) begin
    if (wr_valid)
        mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
end

wire [ADDR_W:0] wr_gray      = wr_ptr ^ (wr_ptr >> 1);
wire [ADDR_W:0] wr_ptr_next  = wr_ptr + (wr_valid ? 1'b1 : 1'b0);
wire [ADDR_W:0] wr_gray_next = wr_ptr_next ^ (wr_ptr_next >> 1);

// -----------------------------------------------------------
// Read-side binary & Gray pointers
// -----------------------------------------------------------
reg [ADDR_W:0] rd_ptr = {(ADDR_W+1){1'b0}};

wire rd_valid = rd_en & ~rd_empty;

always @(posedge rd_clk) begin
    if (rd_rst)
        rd_ptr <= {(ADDR_W+1){1'b0}};
    else if (rd_valid)
        rd_ptr <= rd_ptr + 1'b1;
end

// Registered read from memory — required for BRAM inference
// 1 cycle read latency on rd_clk, but enables CC_BRAM mapping
reg [DATA_WIDTH-1:0] rd_data_reg;
always @(posedge rd_clk) begin
    rd_data_reg <= mem[rd_ptr[ADDR_W-1:0]];
end
assign rd_data = rd_data_reg;

wire [ADDR_W:0] rd_gray      = rd_ptr ^ (rd_ptr >> 1);
wire [ADDR_W:0] rd_ptr_next  = rd_ptr + (rd_valid ? 1'b1 : 1'b0);
wire [ADDR_W:0] rd_gray_next = rd_ptr_next ^ (rd_ptr_next >> 1);

// -----------------------------------------------------------
// 2-FF synchronizers for Gray pointers crossing domains
// -----------------------------------------------------------

// Write Gray -> Read domain
reg [ADDR_W:0] wr_gray_sync1 = {(ADDR_W+1){1'b0}};
reg [ADDR_W:0] wr_gray_sync2 = {(ADDR_W+1){1'b0}};

always @(posedge rd_clk) begin
    if (rd_rst) begin
        wr_gray_sync1 <= {(ADDR_W+1){1'b0}};
        wr_gray_sync2 <= {(ADDR_W+1){1'b0}};
    end else begin
        wr_gray_sync1 <= wr_gray;
        wr_gray_sync2 <= wr_gray_sync1;
    end
end

// Read Gray -> Write domain
reg [ADDR_W:0] rd_gray_sync1 = {(ADDR_W+1){1'b0}};
reg [ADDR_W:0] rd_gray_sync2 = {(ADDR_W+1){1'b0}};

always @(posedge wr_clk) begin
    if (wr_rst) begin
        rd_gray_sync1 <= {(ADDR_W+1){1'b0}};
        rd_gray_sync2 <= {(ADDR_W+1){1'b0}};
    end else begin
        rd_gray_sync1 <= rd_gray;
        rd_gray_sync2 <= rd_gray_sync1;
    end
end

// -----------------------------------------------------------
// Pipelined full flag (write domain)
// Full when: next write Gray == inverted top 2 bits of synced read Gray
// Max 2-3 LUT levels after register.
// -----------------------------------------------------------
always @(posedge wr_clk) begin
    if (wr_rst)
        wr_full <= 1'b0;
    else
        wr_full <= (wr_gray_next == {~rd_gray_sync2[ADDR_W:ADDR_W-1],
                                       rd_gray_sync2[ADDR_W-2:0]});
end

// -----------------------------------------------------------
// Pipelined empty flag (read domain)
// Empty when: next read Gray == synced write Gray
// -----------------------------------------------------------
always @(posedge rd_clk) begin
    if (rd_rst)
        rd_empty <= 1'b1;
    else
        rd_empty <= (rd_gray_next == wr_gray_sync2);
end

endmodule

`resetall
