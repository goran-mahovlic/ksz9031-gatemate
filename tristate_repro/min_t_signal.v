// min_t_signal.v — minimal CC_IOBUF with T from a real signal (toggling counter MSB).
// Expected: pad follows data_in when T=0, Hi-Z (pull-up) when T=1.
`default_nettype none

module fpga (
    input  wire clk_25mhz,
    input  wire data_in,
    inout  wire pad,
    output wire dbg_y,
    output wire dbg_t
);
    (* keep *) reg [23:0] cnt = 24'd0;
    always @(posedge clk_25mhz) cnt <= cnt + 24'd1;

    (* keep *) wire t_sig = cnt[23];     // toggles ~0.7 Hz at 25 MHz
    (* keep *) wire mdio_y;

    (* keep *) CC_IOBUF #(
        .PIN_NAME("UNPLACED")
    ) iobuf_inst (
        .A(data_in),
        .T(t_sig),
        .Y(mdio_y),
        .IO(pad)
    );

    assign dbg_y = mdio_y;
    assign dbg_t = t_sig;
endmodule
