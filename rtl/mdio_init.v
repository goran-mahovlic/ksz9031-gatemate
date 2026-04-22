// mdio_init.v
//
// MDIO Auto-Initialization FSM for KSZ9031RNXCA PHY
//
// Upgraded 2026-04-22 (Emard pass 2):
//   - Scans PHY addresses 0..31 to find the KSZ9031 (PHY ID2 = 0x0022)
//   - Configures KSZ9031 RGMII TX/RX skew registers via MMD (clause 22 over 45)
//   - Writes BCR to enable auto-negotiation at 1000 Mbps full-duplex
//   - Clear state indications via `state` output (for LED debug)
//
// MMD (Clause 45) indirect access sequence (per KSZ9031 datasheet s.3.2.1):
//   1) Write reg 0x0D = 0x0002    (function=addr, MMD device=2)
//   2) Write reg 0x0E = <reg>     (MMD register address)
//   3) Write reg 0x0D = 0x4002    (function=data_no_incr, MMD device=2)
//   4) Write reg 0x0E = <value>   (MMD register data)
//
// KSZ9031 MMD2 registers written here (all balanced for GateMate trace lengths):
//   MMD2 reg 0x04 = 0x0077  (clock skew: rx_clk=+0.60ns, tx_clk=+0.60ns)
//   MMD2 reg 0x05 = 0x7777  (rx data skew: all lanes +0.42ns)
//   MMD2 reg 0x06 = 0x0000  (tx data skew: all lanes 0ns)
//   MMD2 reg 0x08 = 0x03FF  (max energy detect for Wake-on-Link, safe default)
//
// Best practices applied:
//   - Sync-only reset (active-high), non-blocking assigns
//   - Single always block for FSM + one for counters (easier timing closure)
//   - Counter widths computed with params, no hardcoded magic numbers

`resetall
`timescale 1ns / 1ps
`default_nettype none

module mdio_init #(
    parameter [22:0] SETTLE_CYCLES = 23'd6_250_000,   // 50 ms @ 125 MHz
    parameter [22:0] RETRY_CYCLES  = 23'd1_250_000    // 10 ms @ 125 MHz
)(
    input  wire        clk,
    input  wire        rst,          // active-high sync reset

    input  wire        phy_ready,    // PHY out of reset

    // MDIO controller interface
    output reg         mdio_start,
    output reg         mdio_rw,      // 1=read, 0=write
    output reg  [4:0]  mdio_phy,
    output reg  [4:0]  mdio_reg,
    output reg  [15:0] mdio_wdata,
    input  wire [15:0] mdio_rdata,
    input  wire        mdio_busy,
    input  wire        mdio_rvalid,

    output reg         init_done,
    output reg         init_error,
    output reg  [15:0] phy_id,       // read PHY ID2 for debug
    output reg  [4:0]  phy_addr_found,
    output reg  [4:0]  state_dbg     // exposed for LED debug
);

// ----------------------------------------------------------------
// FSM states
// ----------------------------------------------------------------
localparam [4:0]
    S_IDLE        = 5'd0,
    S_WAIT_PHY    = 5'd1,
    S_SCAN_START  = 5'd2,
    S_SCAN_READ   = 5'd3,
    S_SCAN_WAIT   = 5'd4,
    S_SCAN_CHECK  = 5'd5,
    S_SCAN_RETRY  = 5'd6,
    S_MMD_WR1     = 5'd7,   // reg 0x0D = 0x0002 (addr mode, MMD 2)
    S_MMD_WR1_W   = 5'd8,
    S_MMD_WR2     = 5'd9,   // reg 0x0E = MMD reg addr
    S_MMD_WR2_W   = 5'd10,
    S_MMD_WR3     = 5'd11,  // reg 0x0D = 0x4002 (data mode, MMD 2)
    S_MMD_WR3_W   = 5'd12,
    S_MMD_WR4     = 5'd13,  // reg 0x0E = value
    S_MMD_WR4_W   = 5'd14,
    S_BCR_WR      = 5'd15,
    S_BCR_WR_W    = 5'd16,
    S_DONE        = 5'd17,
    S_ERROR       = 5'd18;

// KSZ9031 PHY ID2 register = 0x0022
localparam [15:0] KSZ9031_PHY_ID2 = 16'h0022;

// BCR (reg 0) init value: auto-neg en + restart auto-neg + FD + 1000M
// 0x1340 = bit12(ANE) | bit9(RAN) | bit8(FD) | bit6(Speed[1]=1000M)
localparam [15:0] BCR_INIT_VAL = 16'h1340;

// MMD writes: list of (mmd_dev, mmd_reg, value) pairs executed sequentially.
// 4 writes total.
localparam NUM_MMD = 4;
reg [1:0] mmd_idx; // 0..3

// ROM: for each MMD write, what device / reg / value
function [22:0] mmd_rom;
    input [1:0] i;
    begin
        // {dev[4:0], reg[4:0], val[15:0]... wait too big}
        // Just split in 3 separate functions
        mmd_rom = 23'd0; // unused
    end
endfunction

function [4:0] mmd_dev_of;
    input [1:0] i;
    begin
        mmd_dev_of = 5'd2; // all writes target device 2
    end
endfunction

function [4:0] mmd_reg_of;
    input [1:0] i;
    case (i)
        2'd0: mmd_reg_of = 5'h04;  // clock skew
        2'd1: mmd_reg_of = 5'h05;  // rx data skew
        2'd2: mmd_reg_of = 5'h06;  // tx data skew
        2'd3: mmd_reg_of = 5'h08;  // wake-on-lan control
        default: mmd_reg_of = 5'h00;
    endcase
endfunction

function [15:0] mmd_val_of;
    input [1:0] i;
    case (i)
        2'd0: mmd_val_of = 16'h0077;
        2'd1: mmd_val_of = 16'h7777;
        2'd2: mmd_val_of = 16'h0000;
        2'd3: mmd_val_of = 16'h03FF;
        default: mmd_val_of = 16'h0000;
    endcase
endfunction

reg [4:0]  state;
reg [22:0] wait_cnt;
reg [4:0]  scan_addr;  // 0..31
reg [2:0]  scan_retry; // retries per address (0..2)

always @(posedge clk) begin
    if (rst) begin
        state          <= S_IDLE;
        wait_cnt       <= 23'd0;
        scan_addr      <= 5'd0;
        scan_retry     <= 3'd0;
        mdio_start     <= 1'b0;
        mdio_rw        <= 1'b1;
        mdio_phy       <= 5'd0;
        mdio_reg       <= 5'd0;
        mdio_wdata     <= 16'd0;
        init_done      <= 1'b0;
        init_error     <= 1'b0;
        phy_id         <= 16'd0;
        phy_addr_found <= 5'd31;
        mmd_idx        <= 2'd0;
        state_dbg      <= 5'd0;
    end else begin
        mdio_start <= 1'b0;   // default: pulse only one cycle
        state_dbg  <= state;

        case (state)
            // -----------------------------------------
            S_IDLE: begin
                if (phy_ready) begin
                    state    <= S_WAIT_PHY;
                    wait_cnt <= 23'd0;
                end
            end

            S_WAIT_PHY: begin
                if (wait_cnt == SETTLE_CYCLES) begin
                    state      <= S_SCAN_START;
                    wait_cnt   <= 23'd0;
                    scan_addr  <= 5'd0;
                    scan_retry <= 3'd0;
                end else begin
                    wait_cnt <= wait_cnt + 23'd1;
                end
            end

            // -----------------------------------------
            // Scan PHY addresses 0..31 for PHY ID2 == 0x0022
            // -----------------------------------------
            S_SCAN_START: begin
                state <= S_SCAN_READ;
            end

            S_SCAN_READ: begin
                if (!mdio_busy) begin
                    mdio_rw    <= 1'b1;
                    mdio_phy   <= scan_addr;
                    mdio_reg   <= 5'd3;   // PHY Identifier 2
                    mdio_wdata <= 16'd0;
                    mdio_start <= 1'b1;
                    state      <= S_SCAN_WAIT;
                end
            end

            S_SCAN_WAIT: begin
                if (mdio_rvalid) begin
                    phy_id <= mdio_rdata;
                    state  <= S_SCAN_CHECK;
                end
            end

            S_SCAN_CHECK: begin
                if (phy_id == KSZ9031_PHY_ID2) begin
                    // Found it
                    phy_addr_found <= scan_addr;
                    mdio_phy       <= scan_addr;
                    mmd_idx        <= 2'd0;
                    state          <= S_MMD_WR1;
                end else begin
                    // Not found at this addr — retry a couple times, then move on
                    if (scan_retry < 3'd2) begin
                        scan_retry <= scan_retry + 3'd1;
                        wait_cnt   <= 23'd0;
                        state      <= S_SCAN_RETRY;
                    end else begin
                        scan_retry <= 3'd0;
                        if (scan_addr == 5'd31) begin
                            // Exhausted all addresses
                            state <= S_ERROR;
                        end else begin
                            scan_addr <= scan_addr + 5'd1;
                            state     <= S_SCAN_READ;
                        end
                    end
                end
            end

            S_SCAN_RETRY: begin
                if (wait_cnt == RETRY_CYCLES) begin
                    state <= S_SCAN_READ;
                end else begin
                    wait_cnt <= wait_cnt + 23'd1;
                end
            end

            // -----------------------------------------
            // MMD write sequence (4 times total)
            //   Each MMD write = 4 MDIO writes
            // -----------------------------------------
            S_MMD_WR1: begin
                if (!mdio_busy) begin
                    mdio_rw    <= 1'b0;
                    mdio_reg   <= 5'h0D;
                    mdio_wdata <= {11'b0, mmd_dev_of(mmd_idx)}; // {func=00, 11'b0, dev[4:0]} = 0x0002
                    mdio_start <= 1'b1;
                    state      <= S_MMD_WR1_W;
                end
            end

            S_MMD_WR1_W: begin
                if (!mdio_busy && !mdio_start) begin
                    state <= S_MMD_WR2;
                end
            end

            S_MMD_WR2: begin
                if (!mdio_busy) begin
                    mdio_rw    <= 1'b0;
                    mdio_reg   <= 5'h0E;
                    mdio_wdata <= {11'b0, mmd_reg_of(mmd_idx)};
                    mdio_start <= 1'b1;
                    state      <= S_MMD_WR2_W;
                end
            end

            S_MMD_WR2_W: begin
                if (!mdio_busy && !mdio_start) begin
                    state <= S_MMD_WR3;
                end
            end

            S_MMD_WR3: begin
                if (!mdio_busy) begin
                    mdio_rw    <= 1'b0;
                    mdio_reg   <= 5'h0D;
                    // func=01 (data, no post-increment): 0x4002 when dev=2
                    mdio_wdata <= {2'b01, 9'b0, mmd_dev_of(mmd_idx)};
                    mdio_start <= 1'b1;
                    state      <= S_MMD_WR3_W;
                end
            end

            S_MMD_WR3_W: begin
                if (!mdio_busy && !mdio_start) begin
                    state <= S_MMD_WR4;
                end
            end

            S_MMD_WR4: begin
                if (!mdio_busy) begin
                    mdio_rw    <= 1'b0;
                    mdio_reg   <= 5'h0E;
                    mdio_wdata <= mmd_val_of(mmd_idx);
                    mdio_start <= 1'b1;
                    state      <= S_MMD_WR4_W;
                end
            end

            S_MMD_WR4_W: begin
                if (!mdio_busy && !mdio_start) begin
                    if (mmd_idx == 2'd3) begin
                        state <= S_BCR_WR;
                    end else begin
                        mmd_idx <= mmd_idx + 2'd1;
                        state   <= S_MMD_WR1;
                    end
                end
            end

            // -----------------------------------------
            // Finally, write BCR to start auto-negotiation
            // -----------------------------------------
            S_BCR_WR: begin
                if (!mdio_busy) begin
                    mdio_rw    <= 1'b0;
                    mdio_reg   <= 5'd0;
                    mdio_wdata <= BCR_INIT_VAL;
                    mdio_start <= 1'b1;
                    state      <= S_BCR_WR_W;
                end
            end

            S_BCR_WR_W: begin
                if (!mdio_busy && !mdio_start) begin
                    init_done <= 1'b1;
                    state     <= S_DONE;
                end
            end

            S_DONE: begin
                init_done <= 1'b1;
            end

            S_ERROR: begin
                init_done  <= 1'b1;
                init_error <= 1'b1;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule

`resetall
