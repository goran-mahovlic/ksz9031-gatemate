/*
 * uart_ila.v — Minimal in-system logic analyzer over UART.
 *
 * Simple pipelined design that closes timing at 125 MHz:
 *   - Capture FSM (tiny): writes probe into BRAM at sample rate.
 *   - Emit FSM: reads BRAM, converts to hex, pushes to UART.
 *   - Registered tx_data output (no deep combinational mux).
 *
 * Output format (no headers/footers to keep FSM small):
 *   One line per sample:  "$XXXX\r\n"   (7 bytes)
 *   Where XXXX is the 16-bit sample in hex, MSB first.
 *   The leading '$' is a sync character so a host script can easily
 *   align on record boundaries. One capture block of BUF_DEPTH lines is
 *   emitted per MDIO trigger, then ILA re-arms for the next trigger.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module uart_ila #(
    parameter integer SAMPLE_WIDTH = 16,
    parameter integer BUF_DEPTH    = 128,
    parameter integer ADDR_WIDTH   = 7,
    parameter integer SAMPLE_DIV   = 25
)(
    input  wire                    clk,
    input  wire                    rst,

    input  wire [SAMPLE_WIDTH-1:0] probe,
    input  wire                    trigger,

    output reg  [7:0]              tx_data,
    output reg                     tx_ena,
    input  wire                    tx_busy
);

// ========== Sample rate prescaler ==========
reg [4:0] samp_cnt;
wire samp_tick = (samp_cnt == SAMPLE_DIV - 1);
always @(posedge clk) begin
    if (rst)            samp_cnt <= 5'd0;
    else if (samp_tick) samp_cnt <= 5'd0;
    else                samp_cnt <= samp_cnt + 5'd1;
end

// ========== Trigger rising edge ==========
reg trig_d;
wire trig_rise = trigger & ~trig_d;
always @(posedge clk) begin
    if (rst) trig_d <= 1'b0;
    else     trig_d <= trigger;
end

// ========== Sample buffer (BRAM) ==========
// no_rw_check: writes happen during capture, reads during emit — the two
// phases are mutually exclusive, so yosys doesn't need transparency mux.
(* no_rw_check *)
reg [SAMPLE_WIDTH-1:0] sample_buf [0:BUF_DEPTH-1];
reg [ADDR_WIDTH-1:0]   wr_ptr;
reg [ADDR_WIDTH-1:0]   rd_ptr;
reg                    capturing;   // high while filling buffer
reg                    emit_start;  // pulse: tells emit FSM buffer is ready

// --- Capture FSM (stand-alone) -------------------------------------
always @(posedge clk) begin
    if (rst) begin
        capturing  <= 1'b0;
        wr_ptr     <= {ADDR_WIDTH{1'b0}};
        emit_start <= 1'b0;
    end else begin
        emit_start <= 1'b0;   // default single-cycle pulse
        if (!capturing) begin
            if (trig_rise) begin
                wr_ptr    <= {ADDR_WIDTH{1'b0}};
                capturing <= 1'b1;
            end
        end else begin
            if (samp_tick) begin
                sample_buf[wr_ptr] <= probe;
                if (wr_ptr == BUF_DEPTH - 1) begin
                    capturing  <= 1'b0;
                    emit_start <= 1'b1;
                end else begin
                    wr_ptr <= wr_ptr + {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
                end
            end
        end
    end
end

// ========== Hex conversion (pipelined) ==========
// rd_data is latched from BRAM in S_READ (1 cycle).
// hex0..hex3 are registered in S_PREP (1 more cycle).
reg [SAMPLE_WIDTH-1:0] rd_data;
reg [7:0] hex3, hex2, hex1, hex0;

function [7:0] nib_hex;
    input [3:0] n;
    case (n)
        4'h0: nib_hex = 8'h30; 4'h1: nib_hex = 8'h31;
        4'h2: nib_hex = 8'h32; 4'h3: nib_hex = 8'h33;
        4'h4: nib_hex = 8'h34; 4'h5: nib_hex = 8'h35;
        4'h6: nib_hex = 8'h36; 4'h7: nib_hex = 8'h37;
        4'h8: nib_hex = 8'h38; 4'h9: nib_hex = 8'h39;
        4'hA: nib_hex = 8'h41; 4'hB: nib_hex = 8'h42;
        4'hC: nib_hex = 8'h43; 4'hD: nib_hex = 8'h44;
        4'hE: nib_hex = 8'h45; 4'hF: nib_hex = 8'h46;
        default: nib_hex = 8'h3F;
    endcase
endfunction

// ========== Emit FSM ==========
localparam E_IDLE = 3'd0;
localparam E_READ = 3'd1;
localparam E_PREP = 3'd2;
localparam E_BYTE = 3'd3;

reg [2:0] estate;
reg [2:0] byte_idx;   // 0..6 within the 7-byte line

// Registered tx byte source (flat mux, tiny)
reg [7:0] tx_next;
always @(*) begin
    case (byte_idx)
        3'd0: tx_next = 8'h24;      // '$'
        3'd1: tx_next = hex3;
        3'd2: tx_next = hex2;
        3'd3: tx_next = hex1;
        3'd4: tx_next = hex0;
        3'd5: tx_next = 8'h0D;      // '\r'
        3'd6: tx_next = 8'h0A;      // '\n'
        default: tx_next = 8'h20;
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        estate   <= E_IDLE;
        rd_ptr   <= {ADDR_WIDTH{1'b0}};
        rd_data  <= {SAMPLE_WIDTH{1'b0}};
        hex3     <= 8'h30;
        hex2     <= 8'h30;
        hex1     <= 8'h30;
        hex0     <= 8'h30;
        byte_idx <= 3'd0;
        tx_data  <= 8'h00;
        tx_ena   <= 1'b0;
    end else begin
        tx_ena <= 1'b0;

        case (estate)
            E_IDLE: begin
                if (emit_start) begin
                    rd_ptr <= {ADDR_WIDTH{1'b0}};
                    estate <= E_READ;
                end
            end

            E_READ: begin
                rd_data <= sample_buf[rd_ptr];
                estate  <= E_PREP;
            end

            E_PREP: begin
                hex3     <= nib_hex(rd_data[15:12]);
                hex2     <= nib_hex(rd_data[11:8]);
                hex1     <= nib_hex(rd_data[7:4]);
                hex0     <= nib_hex(rd_data[3:0]);
                byte_idx <= 3'd0;
                estate   <= E_BYTE;
            end

            E_BYTE: begin
                if (!tx_busy && !tx_ena) begin
                    tx_data <= tx_next;
                    tx_ena  <= 1'b1;
                    if (byte_idx == 3'd6) begin
                        byte_idx <= 3'd0;
                        if (rd_ptr == BUF_DEPTH - 1) begin
                            estate <= E_IDLE;   // done with this capture
                        end else begin
                            rd_ptr <= rd_ptr + {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
                            estate <= E_READ;
                        end
                    end else begin
                        byte_idx <= byte_idx + 3'd1;
                    end
                end
            end

            default: estate <= E_IDLE;
        endcase
    end
end

endmodule

`resetall
