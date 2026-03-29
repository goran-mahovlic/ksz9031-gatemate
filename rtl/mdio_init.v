// mdio_init.v
//
// MDIO Auto-Initialization FSM for KSZ9031RNXCC PHY
//
// Automatically configures the PHY after reset by:
//   1. Waiting for PHY settling time (50ms after phy_ready)
//   2. Reading PHY ID register 2 (expect 0x0022 for KSZ9031)
//   3. Writing BCR (reg 0) = 0x1340 to enable auto-negotiation at 1000Mbps FD
//
// Retry logic: up to 3 attempts for PHY ID read with 10ms pause between retries.
// If all retries fail, init_done is asserted with init_error flag.

`timescale 1ns / 1ps

module mdio_init #(
    parameter [4:0] PHY_ADDR       = 5'd7,
    parameter [22:0] SETTLE_CYCLES = 23'd6_250_000,  // 50ms @ 125MHz
    parameter [22:0] RETRY_CYCLES  = 23'd1_250_000   // 10ms @ 125MHz
)(
    input  wire        clk,          // 125 MHz
    input  wire        rst,          // active-high synchronous reset

    input  wire        phy_ready,    // PHY out of reset (phy_rst_n_reg / phy0_reset_n)

    // MDIO controller interface
    output reg         mdio_start,   // pulse to start MDIO transaction
    output reg         mdio_rw,      // 1=read, 0=write
    output reg  [4:0]  mdio_phy,     // PHY address
    output reg  [4:0]  mdio_reg,     // Register address
    output reg  [15:0] mdio_wdata,   // Write data
    input  wire [15:0] mdio_rdata,   // Read data from controller
    input  wire        mdio_busy,    // Controller busy flag
    input  wire        mdio_rvalid,  // Read data valid

    output reg         init_done,    // Initialization complete
    output reg         init_error,   // PHY ID mismatch after all retries
    output reg  [15:0] phy_id        // PHY ID read during init (for debug)
);

// FSM states
localparam [3:0] S_IDLE       = 4'd0;
localparam [3:0] S_WAIT_PHY   = 4'd1;
localparam [3:0] S_READ_ID    = 4'd2;
localparam [3:0] S_WAIT_READ  = 4'd3;
localparam [3:0] S_CHECK_ID   = 4'd4;
localparam [3:0] S_RETRY_WAIT = 4'd5;
localparam [3:0] S_WRITE_BCR  = 4'd6;
localparam [3:0] S_WAIT_WRITE = 4'd7;
localparam [3:0] S_DONE       = 4'd8;

reg [3:0]  state;
reg [22:0] wait_cnt;
reg [1:0]  retry_cnt;    // 0..3 attempts

// Expected PHY ID (KSZ9031 PHY Identifier Register 2, bits [15:0])
localparam [15:0] KSZ9031_PHY_ID2 = 16'h0022;

// BCR value: Auto-Neg Enable | Restart Auto-Neg | Full Duplex | Speed MSB (1000Mbps)
localparam [15:0] BCR_INIT_VAL = 16'h1340;

always @(posedge clk) begin
    if (rst) begin
        state      <= S_IDLE;
        wait_cnt   <= 23'd0;
        retry_cnt  <= 2'd0;
        mdio_start <= 1'b0;
        mdio_rw    <= 1'b1;
        mdio_phy   <= PHY_ADDR;
        mdio_reg   <= 5'd0;
        mdio_wdata <= 16'd0;
        init_done  <= 1'b0;
        init_error <= 1'b0;
        phy_id     <= 16'd0;
    end else begin
        // Default: deassert start pulse after one cycle
        mdio_start <= 1'b0;

        case (state)
            // ---------------------------------------------------
            // S_IDLE: Wait for phy_ready to go high
            // ---------------------------------------------------
            S_IDLE: begin
                if (phy_ready) begin
                    state    <= S_WAIT_PHY;
                    wait_cnt <= 23'd0;
                end
            end

            // ---------------------------------------------------
            // S_WAIT_PHY: 50ms settling time after PHY exits reset
            // ---------------------------------------------------
            S_WAIT_PHY: begin
                if (wait_cnt == SETTLE_CYCLES) begin
                    state    <= S_READ_ID;
                    wait_cnt <= 23'd0;
                end else begin
                    wait_cnt <= wait_cnt + 23'd1;
                end
            end

            // ---------------------------------------------------
            // S_READ_ID: Issue MDIO read of PHY ID register 2
            // ---------------------------------------------------
            S_READ_ID: begin
                if (!mdio_busy) begin
                    mdio_rw    <= 1'b1;        // read
                    mdio_phy   <= PHY_ADDR;
                    mdio_reg   <= 5'd2;        // PHY ID Register 2
                    mdio_wdata <= 16'd0;
                    mdio_start <= 1'b1;        // pulse
                    state      <= S_WAIT_READ;
                end
            end

            // ---------------------------------------------------
            // S_WAIT_READ: Wait for MDIO read to complete
            // ---------------------------------------------------
            S_WAIT_READ: begin
                if (mdio_rvalid) begin
                    phy_id <= mdio_rdata;
                    state  <= S_CHECK_ID;
                end
            end

            // ---------------------------------------------------
            // S_CHECK_ID: Verify PHY ID
            // ---------------------------------------------------
            S_CHECK_ID: begin
                if (phy_id == KSZ9031_PHY_ID2) begin
                    // PHY ID matches — proceed to configure BCR
                    state <= S_WRITE_BCR;
                end else begin
                    // PHY ID mismatch — retry or give up
                    if (retry_cnt == 2'd3) begin
                        // All retries exhausted
                        init_done  <= 1'b1;
                        init_error <= 1'b1;
                        state      <= S_DONE;
                    end else begin
                        retry_cnt <= retry_cnt + 2'd1;
                        wait_cnt  <= 23'd0;
                        state     <= S_RETRY_WAIT;
                    end
                end
            end

            // ---------------------------------------------------
            // S_RETRY_WAIT: 10ms pause before retry
            // ---------------------------------------------------
            S_RETRY_WAIT: begin
                if (wait_cnt == RETRY_CYCLES) begin
                    state    <= S_READ_ID;
                    wait_cnt <= 23'd0;
                end else begin
                    wait_cnt <= wait_cnt + 23'd1;
                end
            end

            // ---------------------------------------------------
            // S_WRITE_BCR: Write Basic Control Register (reg 0)
            //   0x1340 = Auto-Neg En | Restart Auto-Neg | FD | 1000M
            // ---------------------------------------------------
            S_WRITE_BCR: begin
                if (!mdio_busy) begin
                    mdio_rw    <= 1'b0;         // write
                    mdio_phy   <= PHY_ADDR;
                    mdio_reg   <= 5'd0;         // Basic Control Register
                    mdio_wdata <= BCR_INIT_VAL;
                    mdio_start <= 1'b1;         // pulse
                    state      <= S_WAIT_WRITE;
                end
            end

            // ---------------------------------------------------
            // S_WAIT_WRITE: Wait for MDIO write to complete
            // ---------------------------------------------------
            S_WAIT_WRITE: begin
                if (!mdio_busy && !mdio_start) begin
                    init_done <= 1'b1;
                    state     <= S_DONE;
                end
            end

            // ---------------------------------------------------
            // S_DONE: Initialization complete, stay here
            // ---------------------------------------------------
            S_DONE: begin
                init_done <= 1'b1;
            end

            default: begin
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule
