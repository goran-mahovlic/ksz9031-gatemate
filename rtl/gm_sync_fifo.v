/*
 * GateMate-optimized synchronous FIFO
 * - Pipelined (registered) full/empty flags: max 2 LUT levels in critical path
 * - Binary pointers (no Gray code needed — single clock domain)
 * - reg array storage (Yosys maps to CC_BRAM automatically)
 *
 * Used for TX path where logic_clk == tx_clk (same clock domain).
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gm_sync_fifo #(
    parameter DEPTH      = 64,
    parameter DATA_WIDTH = 10   // 8 data + 1 last + 1 user
)(
    input  wire                  clk,
    input  wire                  rst,

    // Write interface
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    output wire                  full,

    // Read interface
    output wire [DATA_WIDTH-1:0] rd_data,
    input  wire                  rd_en,
    output wire                  empty
);

localparam ADDR_W = $clog2(DEPTH);

// -----------------------------------------------------------
// Pointers — extra MSB bit for full/empty distinction
// -----------------------------------------------------------
reg [ADDR_W:0] wr_ptr = {(ADDR_W+1){1'b0}};
reg [ADDR_W:0] rd_ptr = {(ADDR_W+1){1'b0}};

// -----------------------------------------------------------
// Memory
// -----------------------------------------------------------
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

// -----------------------------------------------------------
// Write logic
// -----------------------------------------------------------
wire wr_valid = wr_en & ~full;

always @(posedge clk) begin
    if (rst) begin
        wr_ptr <= {(ADDR_W+1){1'b0}};
    end else if (wr_valid) begin
        wr_ptr <= wr_ptr + 1'b1;
    end
end

always @(posedge clk) begin
    if (wr_valid)
        mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
end

// -----------------------------------------------------------
// Read logic
// -----------------------------------------------------------
wire rd_valid = rd_en & ~empty;

always @(posedge clk) begin
    if (rst) begin
        rd_ptr <= {(ADDR_W+1){1'b0}};
    end else if (rd_valid) begin
        rd_ptr <= rd_ptr + 1'b1;
    end
end

// Registered read from memory — required for BRAM inference
// 1 cycle read latency, but enables CC_BRAM mapping
reg [DATA_WIDTH-1:0] rd_data_reg;
always @(posedge clk) begin
    rd_data_reg <= mem[rd_ptr[ADDR_W-1:0]];
end
assign rd_data = rd_data_reg;

// -----------------------------------------------------------
// Pipelined (registered) full and empty flags
// Max 2 LUT levels: next-pointer compare, then register
// 1 cycle latency, but critical path is clean.
// -----------------------------------------------------------
reg full_reg  = 1'b0;
reg empty_reg = 1'b1;

wire [ADDR_W:0] wr_ptr_next = wr_ptr + (wr_valid ? 1'b1 : 1'b0);
wire [ADDR_W:0] rd_ptr_next = rd_ptr + (rd_valid ? 1'b1 : 1'b0);

always @(posedge clk) begin
    if (rst) begin
        full_reg  <= 1'b0;
        empty_reg <= 1'b1;
    end else begin
        // Full: MSBs differ, lower address bits match
        full_reg  <= (wr_ptr_next[ADDR_W] != rd_ptr_next[ADDR_W]) &&
                     (wr_ptr_next[ADDR_W-1:0] == rd_ptr_next[ADDR_W-1:0]);
        // Empty: pointers identical
        empty_reg <= (wr_ptr_next == rd_ptr_next);
    end
end

assign full  = full_reg;
assign empty = empty_reg;

endmodule

`resetall
