/*
 * mdio_phy_init.v — KSZ9031 MDIO master + init sequencer for ULX5M-GS
 *
 * What the board needs (measured, litex-eth-ulx5m-gs docs/HW_DIAG_20260923_TASK-4999.md):
 *   - the KSZ9031 answers on PHYAD = 3 only (ID 0x0022:0x1622), 0..2 and 4..7 read 0xFFFF;
 *   - a clause-22 frame must have 64 rising MDC edges (32 preamble + 32 frame bits);
 *     with 63 the PHY silently drops every write;
 *   - 100 Mb/s only: reg9 = 0x0000 (no 1000BASE-T advert), reg4 = 0x0101 (100FD),
 *     reg0 = 0x1200 (AN enable + restart AN) -> reg31 = 0x0328 (100FD) after AN.
 *   - 1000 Mb/s (G1000=1): reg9 = 0x0200, reg4 = 0x0001, reg0 = 0x1200 -> reg31 = 0x0348.
 *
 * Bit timing (one bit = MDC_DIV clk cycles):
 *   c == 0          : MDC low, drive next bit (mdio_o/mdio_oe change while MDC is low)
 *   c == MDC_DIV/2-1: sample mdio_i (just before the rising edge; PHY drives 0..300 ns
 *                     after the previous rising edge)
 *   c == MDC_DIV/2  : MDC high (PHY samples our bit here)
 *
 * After init it polls reg1 (BMSR), reg31 (PHY control, speed/duplex), reg2/reg3 forever,
 * so the UART status line always shows live values.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module mdio_phy_init #(
    parameter [4:0]  PHYAD       = 5'd3,
    parameter        MDC_DIV     = 40,            // 50 MHz / 40 = 1.25 MHz MDC
    parameter [23:0] SETTLE      = 24'd5_000_000, // 100 ms @ 50 MHz before first access
    parameter [23:0] POLL_GAP    = 24'd2_500_000, // 50 ms between poll rounds
    parameter        G1000       = 0              // 0: advertise 100FD only, 1: 1000FD only
)(
    input  wire        clk,
    input  wire        rst,          // active-high, sync; hold while PHY is in reset

    output reg         mdc,
    output reg         mdio_o,
    output reg         mdio_oe,      // 1 = FPGA drives the line
    input  wire        mdio_i,

    output reg  [15:0] id1,
    output reg  [15:0] id2,
    output reg  [15:0] bmsr,
    output reg  [15:0] phyctl,       // reg 0x1F
    output reg         init_done,
    output reg  [7:0]  init_tries
);

// ---------------------------------------------------------------- bit engine
reg  [63:0] sh;          // bits still to send, MSB first
reg  [63:0] oem;         // drive enable per bit
reg  [5:0]  bitn;        // current bit period 0..63
reg  [7:0]  c;
reg         busy;
reg         go;
reg         go_rw;       // 1 = read
reg  [4:0]  go_reg;
reg  [15:0] go_data;
reg  [15:0] rd_sh;
reg         done_p;      // one-cycle pulse when a frame finishes

reg mi_s0 = 1'b1, mi_s1 = 1'b1;
always @(posedge clk) begin
    mi_s0 <= mdio_i;
    mi_s1 <= mi_s0;
end

always @(posedge clk) begin
    done_p <= 1'b0;
    if (rst) begin
        busy    <= 1'b0;
        mdc     <= 1'b0;
        mdio_o  <= 1'b1;
        mdio_oe <= 1'b0;
        c       <= 8'd0;
        bitn    <= 6'd0;
    end else if (!busy) begin
        mdc     <= 1'b0;
        mdio_oe <= 1'b0;
        if (go) begin
            busy <= 1'b1;
            c    <= 8'd0;
            bitn <= 6'd0;
            if (go_rw) begin
                sh  <= {32'hFFFF_FFFF, 2'b01, 2'b10, PHYAD, go_reg, 2'b11, 16'hFFFF};
                oem <= {46'h3FFF_FFFF_FFFF, 18'h0};
            end else begin
                sh  <= {32'hFFFF_FFFF, 2'b01, 2'b01, PHYAD, go_reg, 2'b10, go_data};
                oem <= {64{1'b1}};
            end
        end
    end else begin
        if (c == 8'd0) begin
            mdc     <= 1'b0;
            mdio_o  <= sh[63];
            mdio_oe <= oem[63];
        end
        if (c == MDC_DIV/2 - 1) begin
            if (bitn >= 6'd48)
                rd_sh <= {rd_sh[14:0], mi_s1};
        end
        if (c == MDC_DIV/2)
            mdc <= 1'b1;
        if (c == MDC_DIV - 1) begin
            c   <= 8'd0;
            sh  <= {sh[62:0], 1'b1};
            oem <= {oem[62:0], 1'b0};
            if (bitn == 6'd63) begin
                busy    <= 1'b0;
                mdc     <= 1'b0;
                mdio_oe <= 1'b0;
                done_p  <= 1'b1;
            end else begin
                bitn <= bitn + 6'd1;
            end
        end else begin
            c <= c + 8'd1;
        end
    end
end

// ---------------------------------------------------------------- sequencer
// step: 0 R2, 1 R3, 2 W9, 3 W4, 4 W0, 5 R1, 6 R31, 7 R2, 8 R3, 9 wait -> 5
localparam [15:0] R9_VAL = G1000 ? 16'h0200 : 16'h0000;
localparam [15:0] R4_VAL = G1000 ? 16'h0001 : 16'h0101;
localparam [15:0] R0_VAL = 16'h1200;

reg [3:0]  step;
reg [23:0] wait_cnt;
reg        waiting;
reg        issued;

always @(posedge clk) begin
    go <= 1'b0;
    if (rst) begin
        step       <= 4'd0;
        wait_cnt   <= SETTLE;
        waiting    <= 1'b1;
        issued     <= 1'b0;
        init_done  <= 1'b0;
        init_tries <= 8'd0;
        id1        <= 16'h0000;
        id2        <= 16'h0000;
        bmsr       <= 16'h0000;
        phyctl     <= 16'h0000;
    end else if (waiting) begin
        if (wait_cnt == 24'd0)
            waiting <= 1'b0;
        else
            wait_cnt <= wait_cnt - 24'd1;
    end else if (!issued) begin
        issued <= 1'b1;
        go     <= 1'b1;
        case (step)
            4'd0: begin go_rw <= 1'b1; go_reg <= 5'd2;  end
            4'd1: begin go_rw <= 1'b1; go_reg <= 5'd3;  end
            4'd2: begin go_rw <= 1'b0; go_reg <= 5'd9;  go_data <= R9_VAL; end
            4'd3: begin go_rw <= 1'b0; go_reg <= 5'd4;  go_data <= R4_VAL; end
            4'd4: begin go_rw <= 1'b0; go_reg <= 5'd0;  go_data <= R0_VAL; end
            4'd5: begin go_rw <= 1'b1; go_reg <= 5'd1;  end
            4'd6: begin go_rw <= 1'b1; go_reg <= 5'd31; end
            4'd7: begin go_rw <= 1'b1; go_reg <= 5'd2;  end
            default: begin go_rw <= 1'b1; go_reg <= 5'd3; end
        endcase
    end else if (done_p) begin
        issued <= 1'b0;
        case (step)
            4'd0: id1 <= rd_sh;
            4'd1: id2 <= rd_sh;
            4'd5: bmsr <= rd_sh;
            4'd6: phyctl <= rd_sh;
            4'd7: id1 <= rd_sh;
            4'd8: id2 <= rd_sh;
            default: ;
        endcase
        if (step == 4'd1) begin
            // PHY not answering yet (0xFFFF/0x0000): retry the whole init later
            if (id1 != 16'h0022) begin
                step       <= 4'd0;
                waiting    <= 1'b1;
                wait_cnt   <= POLL_GAP;
                init_tries <= init_tries + 8'd1;
            end else begin
                step <= 4'd2;
            end
        end else if (step == 4'd4) begin
            init_done <= 1'b1;
            step      <= 4'd5;
        end else if (step == 4'd8) begin
            step     <= 4'd5;
            waiting  <= 1'b1;
            wait_cnt <= POLL_GAP;
        end else begin
            step <= step + 4'd1;
        end
    end
end

endmodule

`resetall
