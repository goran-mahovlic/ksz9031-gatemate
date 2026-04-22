/*
 * uart_trace.v
 *
 * Small UART-TX emitter that can be driven by a byte-FIFO-like interface.
 * Used as a DEBUG TRACE channel — multiple producers (heartbeat, MDIO trace)
 * push bytes, this module serializes them out the UART at 115200 baud.
 *
 * Interface: push `wr_data` with `wr_en=1` for one cycle. Module queues it
 * into a small synchronous FIFO and drains it through the `uart` TX engine.
 *
 * Design notes:
 *   - 256-deep synchronous FIFO (enough for ~32 trace strings).
 *   - Drops writes when full (trace is best-effort debug).
 *   - Uses existing `uart.v` for baud-rate generation / TX state machine.
 *   - All non-blocking assigns, synchronous reset.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module uart_trace #(
    parameter CLK_FREQ  = 125_000_000,
    parameter BAUD_RATE = 115_200,
    parameter FIFO_AW   = 8
)(
    input  wire       clk,
    input  wire       rst,

    // Producer interface
    input  wire [7:0] wr_data,
    input  wire       wr_en,
    output wire       full,
    output wire       empty,

    // UART TX pin
    output wire       tx,
    input  wire       rx    // not used; tied off high in top
);

    localparam FIFO_DEPTH = (1 << FIFO_AW);

    reg [7:0] mem [0:FIFO_DEPTH-1];
    reg [FIFO_AW:0] wptr;
    reg [FIFO_AW:0] rptr;

    wire [FIFO_AW-1:0] wa = wptr[FIFO_AW-1:0];
    wire [FIFO_AW-1:0] ra = rptr[FIFO_AW-1:0];

    wire fifo_empty = (wptr == rptr);
    wire fifo_full  = ((wptr[FIFO_AW-1:0] == rptr[FIFO_AW-1:0]) &&
                      (wptr[FIFO_AW] != rptr[FIFO_AW]));

    assign empty = fifo_empty;
    assign full  = fifo_full;

    // UART TX signals
    wire       tx_busy;
    reg  [7:0] tx_data;
    reg        tx_ena;

    uart #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) uart_inst (
        .clk(clk),
        .rst(rst),
        .tx_ena(tx_ena),
        .tx_data(tx_data),
        .tx_busy(tx_busy),
        .tx(tx),
        .rx(rx),
        .rx_busy(),
        .rx_error(),
        .rx_data()
    );

    // Write side
    always @(posedge clk) begin
        if (rst) begin
            wptr <= 0;
        end else if (wr_en && !fifo_full) begin
            mem[wa] <= wr_data;
            wptr    <= wptr + 1'b1;
        end
    end

    // Read side: push byte into UART when uart not busy and we have data
    reg [1:0] tx_state;
    localparam T_IDLE = 2'd0;
    localparam T_KICK = 2'd1;
    localparam T_WAIT = 2'd2;
    localparam T_DRAIN = 2'd3;

    // Registered FIFO read output (breaks BRAM output -> UART combinational path)
    reg [7:0] mem_rd_reg;
    always @(posedge clk) begin
        mem_rd_reg <= mem[ra];
    end

    always @(posedge clk) begin
        if (rst) begin
            rptr     <= 0;
            tx_ena   <= 1'b0;
            tx_data  <= 8'd0;
            tx_state <= T_IDLE;
        end else begin
            tx_ena <= 1'b0; // default one-cycle pulse

            case (tx_state)
                T_IDLE: begin
                    if (!fifo_empty && !tx_busy) begin
                        tx_data  <= mem_rd_reg;   // use registered read
                        tx_ena   <= 1'b1;
                        rptr     <= rptr + 1'b1;
                        tx_state <= T_WAIT;
                    end
                end
                T_WAIT: begin
                    // Wait for tx_busy to rise (char accepted)
                    if (tx_busy) tx_state <= T_DRAIN;
                end
                T_DRAIN: begin
                    // Wait for tx_busy to clear, then next char
                    if (!tx_busy) tx_state <= T_IDLE;
                end
                default: tx_state <= T_IDLE;
            endcase
        end
    end

endmodule

`resetall
