/*
 * uart_heartbeat.v
 *
 * Emits a periodic heartbeat ASCII pattern "H\r\n" every ~1 second,
 * independent of MDIO, PHY, and Ethernet. This is the ABSOLUTE GROUND
 * TRUTH pulse: if UART output does not show 'H' within 1s of power-on,
 * the clock/reset path is broken.
 *
 * Best practices applied:
 *   - All registers use non-blocking assignments.
 *   - Synchronous-reset (active-high), driven from reset_sync output.
 *   - Counter width auto-computed via $clog2.
 *   - Registered output (tx_data, tx_ena) — no combinational glue.
 *   - Uses `tx_busy` handshake from uart module to gate next character.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module uart_heartbeat #(
    parameter CLK_FREQ = 125_000_000,   // system clock in Hz
    parameter PERIOD_S = 1              // heartbeat period (seconds)
)(
    input  wire       clk,
    input  wire       rst,              // active-high sync reset
    input  wire       tx_busy,          // from uart
    output reg  [7:0] tx_data,
    output reg        tx_ena,
    output wire       hb_pulse          // 1-cycle pulse each heartbeat (for LED etc.)
);

    // Counter for ~PERIOD_S seconds
    localparam integer TICK_COUNT = CLK_FREQ * PERIOD_S;
    localparam integer CNT_W      = $clog2(TICK_COUNT);

    reg [CNT_W-1:0] tick_cnt;
    reg             tick;

    always @(posedge clk) begin
        if (rst) begin
            tick_cnt <= 0;
            tick     <= 1'b0;
        end else if (tick_cnt == TICK_COUNT - 1) begin
            tick_cnt <= 0;
            tick     <= 1'b1;
        end else begin
            tick_cnt <= tick_cnt + 1'b1;
            tick     <= 1'b0;
        end
    end

    assign hb_pulse = tick;

    // Three-character sequence: 'H' '\r' '\n'
    // State machine walks through chars, waits for !tx_busy before sending each.
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_SEND = 3'd1;
    localparam [2:0] S_WAIT = 3'd2;
    localparam [2:0] S_NEXT = 3'd3;
    localparam [2:0] S_DONE = 3'd4;

    reg [2:0] state;
    reg [1:0] char_idx;
    reg [7:0] char_rom [0:2];

    initial begin
        char_rom[0] = 8'h48; // 'H'
        char_rom[1] = 8'h0D; // '\r'
        char_rom[2] = 8'h0A; // '\n'
    end

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            char_idx <= 2'd0;
            tx_data  <= 8'd0;
            tx_ena   <= 1'b0;
        end else begin
            tx_ena <= 1'b0; // default: pulse only

            case (state)
                S_IDLE: begin
                    char_idx <= 2'd0;
                    if (tick) begin
                        state <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (!tx_busy) begin
                        tx_data <= char_rom[char_idx];
                        tx_ena  <= 1'b1;
                        state   <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    // wait for tx_busy to assert so we know char has been accepted
                    if (tx_busy) begin
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    // wait for tx_busy to clear, then advance to next char
                    if (!tx_busy) begin
                        if (char_idx == 2'd2) begin
                            state <= S_DONE;
                        end else begin
                            char_idx <= char_idx + 1'b1;
                            state    <= S_SEND;
                        end
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`resetall
