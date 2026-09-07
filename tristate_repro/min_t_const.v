// min_t_const.v — minimal CC_IOBUF with T tied to constant 1 (always Hi-Z).
// If toolchain works correctly: pad must follow external pull-up, FPGA never drives.
// Suspected bug: pad follows `data_in` (FPGA drives even though T=1).
`default_nettype none

module fpga (
    input  wire clk_25mhz,
    input  wire data_in,        // tie to a button or known value
    inout  wire pad,            // the tristate pin under test
    output wire dbg_y           // CC_IOBUF input path (for visibility)
);
    (* keep *) wire mdio_y;

    (* keep *) CC_IOBUF #(
        .PIN_NAME("UNPLACED")
    ) iobuf_inst (
        .A(data_in),
        .T(1'b1),               // CONSTANT: always Hi-Z (FPGA must NOT drive)
        .Y(mdio_y),
        .IO(pad)
    );

    assign dbg_y = mdio_y;
endmodule
