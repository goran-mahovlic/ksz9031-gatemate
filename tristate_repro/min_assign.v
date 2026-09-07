// min_assign.v — yosys-inferred CC_IOBUF via simple Verilog idiom.
// `assign pad = en_reg ? data : 1'bz;` — what yosys does with this is the question.
`default_nettype none

module fpga (
    input  wire clk_25mhz,
    input  wire data_in,
    input  wire en_in,
    inout  wire pad,
    output wire dbg_in
);
    (* keep *) reg en_reg = 1'b0;
    (* keep *) reg data_reg = 1'b0;
    always @(posedge clk_25mhz) begin
        en_reg   <= en_in;
        data_reg <= data_in;
    end

    assign pad = en_reg ? data_reg : 1'bz;
    assign dbg_in = pad;
endmodule
