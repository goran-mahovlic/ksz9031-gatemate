/*
 * Simple UART TX+RX — Verilog replacement for DigiKey VHDL uart.vhd
 * Matches exact port interface used in fpga_core.v
 *
 * Parameters:
 *   CLK_FREQ  — system clock frequency in Hz (default 125 MHz)
 *   BAUD_RATE — baud rate (default 115200)
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module uart #(
    parameter CLK_FREQ  = 125_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       reset_n,    // active-high reset (matches original)
    // TX
    input  wire       tx_ena,
    input  wire [7:0] tx_data,
    output wire       tx_busy,
    output wire       tx,
    // RX
    input  wire       rx,
    output wire       rx_busy,
    output wire       rx_error,
    output wire [7:0] rx_data
);

localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

// ============================================================
// TX
// ============================================================
reg [2:0]  tx_state = 0;
reg [15:0] tx_clk_cnt = 0;
reg [2:0]  tx_bit_idx = 0;
reg [7:0]  tx_shift = 0;
reg        tx_out = 1;
reg        tx_active = 0;

localparam TX_IDLE  = 3'd0;
localparam TX_START = 3'd1;
localparam TX_DATA  = 3'd2;
localparam TX_STOP  = 3'd3;

always @(posedge clk) begin
    if (reset_n) begin
        tx_state   <= TX_IDLE;
        tx_out     <= 1;
        tx_active  <= 0;
        tx_clk_cnt <= 0;
        tx_bit_idx <= 0;
    end else begin
        case (tx_state)
            TX_IDLE: begin
                tx_out    <= 1;
                tx_active <= 0;
                tx_clk_cnt <= 0;
                tx_bit_idx <= 0;
                if (tx_ena) begin
                    tx_shift  <= tx_data;
                    tx_active <= 1;
                    tx_state  <= TX_START;
                end
            end
            TX_START: begin
                tx_out <= 0; // start bit
                if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                    tx_clk_cnt <= tx_clk_cnt + 1;
                end else begin
                    tx_clk_cnt <= 0;
                    tx_state   <= TX_DATA;
                end
            end
            TX_DATA: begin
                tx_out <= tx_shift[tx_bit_idx];
                if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                    tx_clk_cnt <= tx_clk_cnt + 1;
                end else begin
                    tx_clk_cnt <= 0;
                    if (tx_bit_idx < 7) begin
                        tx_bit_idx <= tx_bit_idx + 1;
                    end else begin
                        tx_bit_idx <= 0;
                        tx_state   <= TX_STOP;
                    end
                end
            end
            TX_STOP: begin
                tx_out <= 1; // stop bit
                if (tx_clk_cnt < CLKS_PER_BIT - 1) begin
                    tx_clk_cnt <= tx_clk_cnt + 1;
                end else begin
                    tx_clk_cnt <= 0;
                    tx_active  <= 0;
                    tx_state   <= TX_IDLE;
                end
            end
            default: tx_state <= TX_IDLE;
        endcase
    end
end

assign tx      = tx_out;
assign tx_busy = tx_active;

// ============================================================
// RX
// ============================================================
reg [2:0]  rx_state = 0;
reg [15:0] rx_clk_cnt = 0;
reg [2:0]  rx_bit_idx = 0;
reg [7:0]  rx_shift = 0;
reg [7:0]  rx_data_reg = 0;
reg        rx_active = 0;
reg        rx_err = 0;

// 2-stage synchronizer for rx input
reg rx_sync_0 = 1, rx_sync_1 = 1;
always @(posedge clk) begin
    rx_sync_0 <= rx;
    rx_sync_1 <= rx_sync_0;
end
wire rx_in = rx_sync_1;

localparam RX_IDLE  = 3'd0;
localparam RX_START = 3'd1;
localparam RX_DATA  = 3'd2;
localparam RX_STOP  = 3'd3;

always @(posedge clk) begin
    if (reset_n) begin
        rx_state    <= RX_IDLE;
        rx_active   <= 0;
        rx_err      <= 0;
        rx_clk_cnt  <= 0;
        rx_bit_idx  <= 0;
        rx_data_reg <= 0;
    end else begin
        case (rx_state)
            RX_IDLE: begin
                rx_active  <= 0;
                rx_err     <= 0;
                rx_clk_cnt <= 0;
                rx_bit_idx <= 0;
                if (rx_in == 0) begin // start bit detected
                    rx_state  <= RX_START;
                    rx_active <= 1;
                end
            end
            RX_START: begin // sample at middle of start bit
                if (rx_clk_cnt < (CLKS_PER_BIT - 1) / 2) begin
                    rx_clk_cnt <= rx_clk_cnt + 1;
                end else begin
                    rx_clk_cnt <= 0;
                    if (rx_in == 0) begin
                        rx_state <= RX_DATA; // valid start bit
                    end else begin
                        rx_state <= RX_IDLE; // false start
                        rx_active <= 0;
                    end
                end
            end
            RX_DATA: begin
                if (rx_clk_cnt < CLKS_PER_BIT - 1) begin
                    rx_clk_cnt <= rx_clk_cnt + 1;
                end else begin
                    rx_clk_cnt <= 0;
                    rx_shift[rx_bit_idx] <= rx_in;
                    if (rx_bit_idx < 7) begin
                        rx_bit_idx <= rx_bit_idx + 1;
                    end else begin
                        rx_bit_idx <= 0;
                        rx_state   <= RX_STOP;
                    end
                end
            end
            RX_STOP: begin
                if (rx_clk_cnt < CLKS_PER_BIT - 1) begin
                    rx_clk_cnt <= rx_clk_cnt + 1;
                end else begin
                    rx_clk_cnt <= 0;
                    if (rx_in == 1) begin
                        rx_data_reg <= rx_shift;
                        rx_err      <= 0;
                    end else begin
                        rx_err <= 1; // framing error
                    end
                    rx_active <= 0;
                    rx_state  <= RX_IDLE;
                end
            end
            default: rx_state <= RX_IDLE;
        endcase
    end
end

assign rx_data  = rx_data_reg;
assign rx_busy  = rx_active;
assign rx_error = rx_err;

endmodule

`resetall
