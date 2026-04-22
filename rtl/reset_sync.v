/*
 * reset_sync.v
 *
 * Async-assert, sync-release reset synchronizer.
 * Best practice: register with preset, 2 flops deep, both driven by an
 * async reset input (pll_lock_n or button_n or power-on).
 *
 * Behavior:
 *   - When async_rst_n = 0 → both flops asynchronously clear → rst_sync = 1 immediately.
 *   - When async_rst_n = 1 → flops clock in 1 through two pipeline stages → rst_sync drops to 0
 *     synchronously with `clk`, i.e. synchronous release.
 *
 * Output `rst_sync` is ACTIVE-HIGH (1 = in reset).
 *
 * Use ONE of these per clock domain.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module reset_sync (
    input  wire clk,
    input  wire async_rst_n,   // active-low async reset in (e.g. PLL locked & !btn)
    output wire rst_sync       // active-high sync reset out (1 = in reset)
);

    reg r0 = 1'b0;
    reg r1 = 1'b0;

    always @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) begin
            r0 <= 1'b0;
            r1 <= 1'b0;
        end else begin
            r0 <= 1'b1;
            r1 <= r0;
        end
    end

    assign rst_sync = ~r1;

endmodule

`resetall
