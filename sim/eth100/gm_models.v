// Behavioural models of the GateMate primitives used by eth100_top (simulation only).
`timescale 1ns/1ps
module CC_PLL #(parameter REF_CLK="25.0", parameter OUT_CLK="50.0", parameter PERF_MD="ECONOMY",
                parameter LOW_JITTER=1, parameter CI_FILTER_CONST=2, parameter CP_FILTER_CONST=4,
                parameter LOCK_REQ=1, parameter CLK180_DOUB=0, parameter CLK270_DOUB=0) (
    input CLK_REF, input CLK_FEEDBACK, input USR_CLK_REF, input USR_LOCKED_STDY_RST,
    output reg CLK0 = 1'b0, output reg CLK90 = 1'b0, output CLK180, output CLK270,
    output USR_PLL_LOCKED, output USR_PLL_LOCKED_STDY, output CLK_REF_OUT);
    // 50 MHz only (the design never asks for anything else)
    always #10 CLK0 = ~CLK0;
    initial begin #5; forever #10 CLK90 = ~CLK90; end
    assign CLK180 = ~CLK0;
    assign CLK270 = ~CLK90;
    assign USR_PLL_LOCKED = 1'b1;
    assign USR_PLL_LOCKED_STDY = 1'b1;
    assign CLK_REF_OUT = CLK_REF;
endmodule
module CC_USR_RSTN (output reg USR_RSTN);
    initial begin USR_RSTN = 1'b0; #200 USR_RSTN = 1'b1; end
endmodule
module CC_IDDR #(parameter CLK_INV=0) (input D, input CLK, output reg Q0, output reg Q1);
    always @(posedge CLK) Q0 <= D;
    always @(negedge CLK) Q1 <= D;
endmodule
module CC_IOBUF #(parameter PULLUP=0, parameter PULLDOWN=0, parameter KEEPER=0,
                  parameter DRIVE="3", parameter SLEW="SLOW", parameter DELAY_IBF=0,
                  parameter DELAY_OBF=0, parameter FF_IBF=0, parameter FF_OBF=0) (
    input A, input T, output Y, inout IO);
    assign IO = T ? 1'bz : A;
    assign Y = IO;
endmodule
