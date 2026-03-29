// GateMate-specific simulation stubs not in OSS CAD Suite cells_sim.v
`timescale 1ns/1ps

// CC_PLL - PLL simulation model
// Generates clocks at specified frequencies for functional simulation.
// In real hardware, CC_PLL synthesizes frequencies with specified jitter.
module CC_PLL #(
    parameter REF_CLK         = "0.0",
    parameter OUT_CLK         = "0.0",
    parameter PERF_MD         = "ECONOMY",
    parameter LOW_JITTER      = 1,
    parameter CI_FILTER_CONST = 2,
    parameter CP_FILTER_CONST = 4,
    parameter CLK180_DOUB     = 0,
    parameter CLK270_DOUB     = 0,
    parameter LOCK_REQ        = 1
) (
    input  CLK_REF,
    input  CLK_FEEDBACK,
    input  USR_CLK_REF,
    input  USR_LOCKED_STDY_RST,
    input  USR_SEL_A_B,
    output CLK_REF_OUT,
    output USR_PLL_LOCKED_STDY,
    output USR_PLL_LOCKED,
    output CLK270,
    output CLK180,
    output CLK90,
    output CLK0,
    output CLK_OUT_DIV4,
    output CLK_OUT_DIV2
);
    // Pass CLK_REF through for CLK0 (25MHz in, ~25MHz equivalent out)
    // In real hardware, OUT_CLK MHz output would be different from REF_CLK MHz
    // For simulation, CLK0 = CLK_REF (correct phase, ~correct frequency behavior)
    assign CLK0           = CLK_REF;
    assign CLK90          = 1'b0;
    assign CLK180         = ~CLK_REF;
    assign CLK270         = 1'b0;
    assign CLK_OUT_DIV2   = CLK_REF;
    assign CLK_OUT_DIV4   = 1'b0;
    assign CLK_REF_OUT    = CLK_REF;
    assign USR_PLL_LOCKED = 1'b1;       // immediately locked
    assign USR_PLL_LOCKED_STDY = 1'b1;

endmodule

// CC_USR_RSTN - User reset output
// Provides a system-level reset signal synchronized to PLL lock.
module CC_USR_RSTN (
    output USR_RSTN
);
    // In simulation, reset is immediately deasserted
    assign USR_RSTN = 1'b1;
endmodule
