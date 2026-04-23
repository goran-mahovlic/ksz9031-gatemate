/*
 * fpga_phase4.v — MDIO diagnostic with plain-English UART output
 *
 * Purpose: read KSZ9031 PHY registers and print results in human-readable
 * form every 1 second. Cycles through four registers to probe the PHY:
 *   reg 0x02 = PHY ID1  (expected 0x0022 for KSZ9031)
 *   reg 0x03 = PHY ID2  (expected 0x1620..0x162F)
 *   reg 0x00 = Basic Control
 *   reg 0x01 = Basic Status
 *
 * UART output example (every second):
 *   t=0003 rst=0 pll=1 phyrstn=1 mdio=1 | phy=00 reg=02 val=0022 KSZ9031-OK
 *   t=0004 rst=0 pll=1 phyrstn=1 mdio=1 | phy=00 reg=03 val=1622 OK
 *
 * Clock: clk_125 (from PLL) — matches upstream and allows 1 Hz counter
 *        with a sensible-sized prescaler.
 * Reset: CC_USR_RSTN primitive + btn[2] + 22-bit counter for PHY reset.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module fpga (
    input  wire        clk_25mhz,
    input  wire [2:0]  btn,
    output wire [7:0]  led,
    output wire        uart_tx,
    input  wire        uart_rx,

    output wire        eth_tx_clk,
    output wire [3:0]  eth_txd,
    output wire        eth_tx_ctl,
    input  wire        eth_rx_clk,
    input  wire [3:0]  eth_rxd,
    input  wire        eth_rx_ctl,
    output wire        eth_rst_n,
    output wire        eth_mdc,
    inout  wire        eth_mdio
);

// --- Unused RGMII outputs (keep safe defaults) ---
assign eth_tx_clk = 1'b0;
assign eth_txd    = 4'd0;
assign eth_tx_ctl = 1'b0;

// ============================================================
// Clocking — run main logic at 25 MHz (from the pad directly).
// Avoids tight timing on big shift-register concatenation while
// keeping UART (115200 baud) and MDIO (2.5 MHz MDC) both in spec.
// PLL still instantiated so `pll_locked` gates reset; clock_5x is
// unused here.
// ============================================================
wire clk_125_unused, clk_125_90_unused, pll_locked;
pll pll_inst (
    .clock_in       (clk_25mhz),
    .clock_5x_out   (clk_125_unused),
    .clock_5x_90_out(clk_125_90_unused),
    .lock_out       (pll_locked)
);
wire clk = clk_25mhz;

// ============================================================
// Reset — CC_USR_RSTN + btn[2] + power-on counter. Matches
// upstream fpga.v. btn[2] active-low on ULX5M-GS.
// ============================================================
wire usr_rst_n;
CC_USR_RSTN usr_rstn_inst ( .USR_RSTN(usr_rst_n) );

reg [3:0] rst_cnt = 4'hF;
reg       rst_int = 1'b1;
always @(posedge clk) begin
    if (!usr_rst_n || !btn[2] || !pll_locked) begin
        rst_cnt <= 4'hF;
        rst_int <= 1'b1;
    end else if (rst_cnt != 4'd0) begin
        rst_cnt <= rst_cnt - 4'd1;
        rst_int <= 1'b1;
    end else begin
        rst_int <= 1'b0;
    end
end
wire rst = rst_int;

// PHY reset — hold low ~167 ms at 25 MHz (sticky high once set)
reg [21:0] phy_rst_cnt       = 22'h3FFFFF;
reg        phy_rst_n_reg     = 1'b0;
always @(posedge clk) begin
    if (!phy_rst_n_reg) begin
        if (phy_rst_cnt == 22'd0) phy_rst_n_reg <= 1'b1;
        else                      phy_rst_cnt   <= phy_rst_cnt - 22'd1;
    end
end
assign eth_rst_n = phy_rst_n_reg;
wire phy_ready = phy_rst_n_reg;

// ============================================================
// MDIO controller (simple tri-state form). Default 2.5 MHz MDC.
// ============================================================
reg         mdio_start  = 1'b0;
reg         mdio_rw     = 1'b1;        // read
reg  [4:0]  mdio_phy    = 5'd0;
reg  [4:0]  mdio_reg    = 5'd2;
reg  [15:0] mdio_wdata  = 16'd0;
wire [15:0] mdio_rdata;
wire        mdio_busy;
wire        mdio_rvalid;

wire mdio_out_w, mdio_oe_w, mdio_in_w;
mdio_controller #(
    .SYS_CLK_FREQ(25_000_000),
    .MDC_FREQ    (2_500_000)
) mdio_ctrl_inst (
    .clk      (clk),
    .rst      (rst),
    .start    (mdio_start),
    .rw       (mdio_rw),
    .phy_addr (mdio_phy),
    .reg_addr (mdio_reg),
    .wdata    (mdio_wdata),
    .rdata    (mdio_rdata),
    .busy     (mdio_busy),
    .rvalid   (mdio_rvalid),
    .mdc      (eth_mdc),
    .mdio_out (mdio_out_w),
    .mdio_oe  (mdio_oe_w),
    .mdio_i   (mdio_in_w)
);

// Top-level CC_IOBUF with explicit PULLUP=1 (so idle bus floats HIGH).
CC_IOBUF #(
    .PIN_NAME("UNPLACED"),
    .DRIVE("12"),
    .PULLUP(1'b1),
    .PULLDOWN(1'b0),
    .SLEW("FAST")
) mdio_iobuf (
    .A(mdio_out_w),
    .T(~mdio_oe_w),        // T=0 = drive pad; T=1 = Hi-Z
    .Y(mdio_in_w),
    .IO(eth_mdio)
);

// Latch last successful read (and snap the conditions for the UART print)
reg [15:0] last_val     = 16'hDEAD;
reg [4:0]  last_reg     = 5'd0;
reg        last_rvalid  = 1'b0;
always @(posedge clk) begin
    if (rst) begin
        last_val    <= 16'hDEAD;
        last_reg    <= 5'd0;
        last_rvalid <= 1'b0;
    end else if (mdio_rvalid) begin
        last_val    <= mdio_rdata;
        last_reg    <= mdio_reg;
        last_rvalid <= 1'b1;
    end
end

// Expose MDIO line for status print (2-FF sync) — sample IOBUF output,
// NOT the inout pad directly (avoids "multiple input buffer" synth error).
reg mdio_pin_s0, mdio_pin_s1;
always @(posedge clk) begin
    mdio_pin_s0 <= mdio_in_w;
    mdio_pin_s1 <= mdio_pin_s0;
end
wire mdio_pin_level = mdio_pin_s1;

// ============================================================
// 1 Hz tick + uptime seconds counter
// ============================================================
reg [26:0] sec_cnt = 27'd0;
reg [15:0] uptime  = 16'd0;
wire tick_1hz = (sec_cnt == 27'd25_000_000 - 1);
always @(posedge clk) begin
    if (rst) begin
        sec_cnt <= 27'd0;
        uptime  <= 16'd0;
    end else if (tick_1hz) begin
        sec_cnt <= 27'd0;
        uptime  <= uptime + 16'd1;
    end else begin
        sec_cnt <= sec_cnt + 27'd1;
    end
end

// ============================================================
// Trigger MDIO read once per second after phy_ready
//  Cycle: reg 2 (ID1), reg 3 (ID2), reg 0 (BCR), reg 1 (BSR)
// ============================================================
reg [1:0] reg_sel = 2'd0;
always @(posedge clk) begin
    if (rst) begin
        mdio_start <= 1'b0;
        mdio_rw    <= 1'b1;
        mdio_phy   <= 5'd0;
        mdio_reg   <= 5'd2;
        mdio_wdata <= 16'd0;
        reg_sel    <= 2'd0;
    end else if (tick_1hz && phy_ready && !mdio_busy && !mdio_start) begin
        // Select register for this cycle
        case (reg_sel)
            2'd0: mdio_reg <= 5'd2;  // PHY ID1
            2'd1: mdio_reg <= 5'd3;  // PHY ID2
            2'd2: mdio_reg <= 5'd0;  // BCR
            2'd3: mdio_reg <= 5'd1;  // BSR
        endcase
        mdio_rw    <= 1'b1;
        mdio_phy   <= 5'd0;
        mdio_start <= 1'b1;
        reg_sel    <= reg_sel + 2'd1;
    end else if (mdio_start) begin
        mdio_start <= 1'b0;
    end
end

// ============================================================
// UART (from upstream uart.v) — shared 115200 8N1
// ============================================================
reg        uart_wr_en = 1'b0;
reg  [7:0] uart_wr_d  = 8'd0;
wire       uart_busy;

uart #(
    .CLK_FREQ (25_000_000),
    .BAUD_RATE(115_200)
) uart_inst (
    .clk     (clk),
    .rst     (rst),
    .tx_ena  (uart_wr_en),
    .tx_data (uart_wr_d),
    .tx_busy (uart_busy),
    .tx      (uart_tx),
    .rx      (uart_rx),
    .rx_busy (),
    .rx_error(),
    .rx_data ()
);

// ============================================================
// Message emitter — SHIFT REGISTER approach.
// Previously used reg[7:0] line_buf[0:57] which yosys inferred as
// memory with a SINGLE write port — writing 58 slots in one cycle
// silently dropped most writes, producing garbage UART output.
// Flat register vector has one FF per bit, all writable in one cycle.
//
// Format (57 bytes incl CRLF):
//   "t=XXXX rst=X pll=X prst=X mdio=X phy=XX reg=XX val=XXXX\r\n"
// ============================================================
localparam integer LINE_LEN = 57;
reg [LINE_LEN*8-1:0] line_sr = {(LINE_LEN*8){1'b0}};
reg [6:0]            tx_cnt  = 7'd0;  // remaining bytes, 0..LINE_LEN

function [7:0] nib_hex;
    input [3:0] n;
    nib_hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
endfunction

wire tx_active = (tx_cnt != 7'd0);

// DEBUG: instead of dynamic line, emit a known fixed test pattern every
// time mdio_rvalid fires. If THIS comes out clean on UART, the emitter
// pipeline works and the bug is in the dynamic concat. If even this is
// garbled, UART TX or the shift-register itself is broken.
always @(posedge clk) begin
    if (rst) begin
        tx_cnt  <= 7'd0;
    end else if (!tx_active && mdio_rvalid) begin
        // Hard-coded 57-byte pattern (0-9 repeated + CRLF).
        line_sr <= { "0123456789012345678901234567890123456789012345678901234",
                     8'h0D, 8'h0A };
        tx_cnt  <= 7'd57;
    end else if (tx_active && !uart_busy && !uart_wr_en) begin
        uart_wr_d  <= line_sr[LINE_LEN*8-1 -: 8];
        uart_wr_en <= 1'b1;
    end else if (uart_wr_en) begin
        uart_wr_en <= 1'b0;
        line_sr    <= {line_sr[LINE_LEN*8-9:0], 8'h00};
        tx_cnt     <= tx_cnt - 7'd1;
    end
end

// ============================================================
// LEDs — mirror key signals
// ============================================================
assign led[0] = uptime[0];           // 1 Hz blink
assign led[1] = phy_rst_n_reg;       // PHY reset released
assign led[2] = last_rvalid;         // got at least one valid read
assign led[3] = (last_val == 16'h0022); // PHY ID matched once
assign led[4] = pll_locked;
assign led[5] = mdio_pin_level;      // MDIO line value right now
assign led[6] = uart_busy;
assign led[7] = rst;

endmodule

`resetall
