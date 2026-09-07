/*
 * pll_50mhz.v — 25 MHz → 50 MHz PLL for Phase 5 debug build.
 *
 * 50 MHz gives enough budget to close timing on the UART-ILA BRAM paths
 * (GateMate routing is slow relative to the architecture's 125 MHz cap),
 * while still being plenty for 2.5 MHz MDC and 115200 baud UART.
 */

module pll_50mhz (
    input  wire clock_in,
    output wire clock_out,
    output reg  lock_out
);

initial lock_out = 1'b0;

wire usr_pll_lock_stdy, usr_pll_lock;

CC_PLL #(
    .REF_CLK("25.0"),
    .OUT_CLK("50.0"),
    .LOW_JITTER(1),
    .CI_FILTER_CONST(2),
    .CP_FILTER_CONST(4)
) pll50 (
    .CLK_REF(clock_in), .CLK_FEEDBACK(1'b0), .USR_CLK_REF(1'b0),
    .USR_LOCKED_STDY_RST(1'b0), .USR_PLL_LOCKED_STDY(usr_pll_lock_stdy), .USR_PLL_LOCKED(usr_pll_lock),
    .CLK270(), .CLK180(), .CLK90(), .CLK0(clock_out), .CLK_REF_OUT()
);

reg locked_s1 = 1'b0;
always @(posedge clock_out) begin
    locked_s1 <= usr_pll_lock;
    lock_out  <= locked_s1;
end

endmodule
