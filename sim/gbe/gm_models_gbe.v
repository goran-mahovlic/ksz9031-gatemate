// Behavioural models of the GateMate primitives used by gbe_top (simulation only).
`timescale 1ns/1ps
module CC_PLL #(parameter REF_CLK="25.0", parameter OUT_CLK="125.0", parameter PERF_MD="ECONOMY",
                parameter LOW_JITTER=1, parameter CI_FILTER_CONST=2, parameter CP_FILTER_CONST=4,
                parameter LOCK_REQ=1, parameter CLK180_DOUB=0, parameter CLK270_DOUB=0) (
    input CLK_REF, input CLK_FEEDBACK, input USR_CLK_REF, input USR_LOCKED_STDY_RST,
    output reg CLK0 = 1'b0, output reg CLK90 = 1'b0, output CLK180, output CLK270,
    output USR_PLL_LOCKED, output USR_PLL_LOCKED_STDY, output CLK_REF_OUT);
    // 125 MHz only; CLK90 lags CLK0 by 2 ns
    always #4 CLK0 = ~CLK0;
    initial begin #2; forever #4 CLK90 = ~CLK90; end
    assign CLK180 = ~CLK0;
    assign CLK270 = ~CLK90;
    assign USR_PLL_LOCKED = 1'b1;
    assign USR_PLL_LOCKED_STDY = 1'b1;
    assign CLK_REF_OUT = CLK_REF;
endmodule
module CC_USR_RSTN (output reg USR_RSTN);
    initial begin USR_RSTN = 1'b0; #200 USR_RSTN = 1'b1; end
endmodule
module CC_BUFG (input I, output O);
    assign O = I;
endmodule
module CC_IDDR #(parameter CLK_INV=0) (input D, input CLK, output reg Q0 = 1'b0, output reg Q1 = 1'b0);
    always @(posedge CLK) Q0 <= D;
    always @(negedge CLK) Q1 <= D;
endmodule
module CC_ODDR #(parameter CLK_INV=0) (input D0, input D1, input CLK, input DDR, output Q);
    reg q0 = 1'b0, q1 = 1'b0;
    always @(posedge CLK) q0 <= D0;
    always @(negedge CLK) q1 <= D1;
    assign Q = DDR ? q0 : q1;
endmodule
module CC_DFF #(parameter CLK_INV=0, parameter EN_INV=0, parameter SR_INV=0, parameter SR_VAL=0)
    (input D, input CLK, input EN, input SR, output reg Q = 1'b0);
    wire c = CLK_INV ? ~CLK : CLK;
    always @(posedge c) if (EN ^ EN_INV) Q <= D;
endmodule
module CC_IOBUF #(parameter PULLUP=0, parameter PULLDOWN=0, parameter KEEPER=0,
                  parameter DRIVE="3", parameter SLEW="SLOW", parameter DELAY_IBF=0,
                  parameter DELAY_OBF=0, parameter FF_IBF=0, parameter FF_OBF=0) (
    input A, input T, output Y, inout IO);
    assign IO = T ? 1'bz : A;
    assign Y = IO;
endmodule
