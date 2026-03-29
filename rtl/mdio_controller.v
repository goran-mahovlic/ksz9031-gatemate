// mdio_controller.v
//
// A simple MDIO (Clause 22) controller for communicating with an Ethernet PHY.
//
// Features:
// - Parameterized for different system clock frequencies.
// - Supports both read and write operations.
// - Standard two-wire MDIO interface (MDC, MDIO).

`timescale 1ns / 1ps

module mdio_controller #(
    // Users of this module can change these values
    parameter SYS_CLK_FREQ = 125_000_000, // 125 MHz system clock
    parameter MDC_FREQ     = 2_500_000   // 2.5 MHz MDC clock
)(
    // System Signals
    input             clk,
    input             rst_n,

    // User Interface - Inputs
    input             start,      // Start transaction
    input             rw,         // 1 for read, 0 for write
    input      [4:0]  phy_addr,   // PHY Address
    input      [4:0]  reg_addr,   // Register Address
    input      [15:0] wdata,      // Data to write

    // User Interface - Outputs
    output reg [15:0] rdata,      // Data read from PHY
    output            busy,       // Controller is busy
    output reg        rvalid,     // Read data is valid

    // PHY Interface
    output            mdc,        // MDIO Clock
    inout             mdio        // MDIO Data
);

//----------------------------------------------------------------
// Parameters and Internal Signals
//----------------------------------------------------------------

// FSM State Definitions
localparam S_IDLE     = 4'h0;
localparam S_PREAMBLE = 4'h1;
localparam S_START    = 4'h2;
localparam S_OP       = 4'h3;
localparam S_PHYAD    = 4'h4;
localparam S_REGAD    = 4'h5;
localparam S_TA       = 4'h6;
localparam S_DATA     = 4'h7;
localparam S_DONE     = 4'h8;

// Internal Registers
reg [3:0] current_state, next_state;
reg [4:0] bit_cnt, bit_cnt_next;

// MDC Clock Generation
localparam DIV_FACTOR = SYS_CLK_FREQ / MDC_FREQ;
parameter CNT_WIDTH  = $clog2(DIV_FACTOR);
reg [CNT_WIDTH-1:0] clk_div_cnt;
wire mdc_tick = (clk_div_cnt == DIV_FACTOR - 1);

// MDIO Tri-state Buffer Control
reg mdio_en_reg, mdio_en_reg_next;
reg mdio_out_reg, mdio_out_reg_next;

// Read Data Capture
reg [15:0] rdata_reg;
reg [15:0] rdata_next;
reg rvalid_next;

//----------------------------------------------------------------
// Continuous Assignments
//----------------------------------------------------------------

// MDC Clock Output
assign mdc = (clk_div_cnt < (DIV_FACTOR / 2));

// MDIO Tri-state Buffer for MDIO pin
assign mdio = (mdio_en_reg) ? mdio_out_reg : 1'bz;

// Busy Signal
assign busy = (current_state != S_IDLE);

//----------------------------------------------------------------
// Sequential Logic (Registers)
//----------------------------------------------------------------

// MDC Clock Divider Counter
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clk_div_cnt <= 0;
    end else if (clk_div_cnt == DIV_FACTOR - 1) begin
        clk_div_cnt <= 0;
    end else begin
        clk_div_cnt <= clk_div_cnt + 1;
    end
end

// Main Sequential Block for all control registers
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_state <= S_IDLE;
        bit_cnt       <= 0;
        mdio_en_reg   <= 1'b0;
        mdio_out_reg  <= 1'b0;
        rdata_reg     <= 16'd0;
        rdata         <= 16'd0;
        rvalid        <= 1'b0;
    end else begin
        // Update registers on the system clock
        current_state <= next_state;
        bit_cnt       <= bit_cnt_next;
        mdio_en_reg   <= mdio_en_reg_next;
        mdio_out_reg  <= mdio_out_reg_next;
        rdata         <= rdata_next;
        rvalid        <= rvalid_next;

        // The read data shift register is only updated on the mdc_tick
        if (mdc_tick && current_state == S_DATA && rw) begin
            rdata_reg <= {rdata_reg[14:0], mdio};
        end
    end
end

//----------------------------------------------------------------
// Combinational Logic (Control Brain)
//----------------------------------------------------------------
always @(*) begin
    // Default assignments to prevent latches
    next_state        = current_state;
    bit_cnt_next      = bit_cnt;
    mdio_en_reg_next  = mdio_en_reg;
    mdio_out_reg_next = mdio_out_reg;
    rdata_next        = rdata;
    rvalid_next       = 1'b0; // rvalid is a single-cycle pulse

    // --- FSM State Transition Logic ---
    case (current_state)
        S_IDLE: begin
            if (start) begin
                next_state = S_PREAMBLE;
                bit_cnt_next = 0;
            end
        end
        S_PREAMBLE: begin
            if (mdc_tick) begin
                if (bit_cnt == 31) begin
                    next_state = S_START;
                    bit_cnt_next = 0;
                end else begin
                    bit_cnt_next = bit_cnt + 1;
                end
            end
        end
        S_START: begin
            if (mdc_tick) begin
                if (bit_cnt == 1) begin next_state = S_OP; bit_cnt_next = 0; end
                else begin bit_cnt_next = bit_cnt + 1; end
            end
        end
        S_OP: begin
            if (mdc_tick) begin
                if (bit_cnt == 1) begin next_state = S_PHYAD; bit_cnt_next = 0; end
                else begin bit_cnt_next = bit_cnt + 1; end
            end
        end
        S_PHYAD: begin
            if (mdc_tick) begin
                if (bit_cnt == 4) begin next_state = S_REGAD; bit_cnt_next = 0; end
                else begin bit_cnt_next = bit_cnt + 1; end
            end
        end
        S_REGAD: begin
            if (mdc_tick) begin
                if (bit_cnt == 4) begin next_state = S_TA; bit_cnt_next = 0; end
                else begin bit_cnt_next = bit_cnt + 1; end
            end
        end
        S_TA: begin
            if (mdc_tick) begin
                if (bit_cnt == 1) begin next_state = S_DATA; bit_cnt_next = 0; end
                else begin bit_cnt_next = bit_cnt + 1; end
            end
        end
        S_DATA: begin
            if (mdc_tick) begin
                if (bit_cnt == 15) begin
                    next_state = S_DONE;
                    if (rw) begin
                        rdata_next = {rdata_reg[14:0], mdio};
                        rvalid_next = 1'b1;
                    end
                end else begin
                    bit_cnt_next = bit_cnt + 1;
                end
            end
        end
        S_DONE: begin
            next_state = S_IDLE;
        end
        default: begin
            next_state = S_IDLE;
        end
    endcase

    // --- Output Logic ---
    // MDIO Enable
    case (current_state)
        S_PREAMBLE, S_START, S_OP, S_PHYAD, S_REGAD: mdio_en_reg_next = 1'b1;
        S_TA, S_DATA: mdio_en_reg_next = ~rw;
        default: mdio_en_reg_next = 1'b0;
    endcase

    // MDIO Data Out
    case (current_state)
        S_PREAMBLE: mdio_out_reg_next = 1'b1;
        S_START:    mdio_out_reg_next = (bit_cnt == 0) ? 1'b0 : 1'b1; // Pattern '01'
        S_OP:       mdio_out_reg_next = (rw) ? (bit_cnt == 0) : (bit_cnt == 1); // Read '10', Write '01'
        S_PHYAD:    mdio_out_reg_next = phy_addr[4 - bit_cnt];
        S_REGAD:    mdio_out_reg_next = reg_addr[4 - bit_cnt];
        S_TA:       mdio_out_reg_next = (bit_cnt == 0) ? 1'b1 : 1'b0; // Pattern '10' for write
        S_DATA:     mdio_out_reg_next = wdata[15 - bit_cnt];
        default:    mdio_out_reg_next = 1'b0;
    endcase
end

endmodule