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
// Clocking
// ============================================================
wire clk_125, clk_125_90, pll_locked;
pll pll_inst (
    .clock_in      (clk_25mhz),
    .clock_5x_out  (clk_125),
    .clock_5x_90_out(clk_125_90),
    .lock_out      (pll_locked)
);
wire clk = clk_125;

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

// PHY reset — hold low ~33 ms after rst release (sticky high once set)
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

mdio_controller #(
    .SYS_CLK_FREQ(125_000_000),
    .MDC_FREQ    (2_500_000)
) mdio_ctrl_inst (
    .clk     (clk),
    .rst     (rst),
    .start   (mdio_start),
    .rw      (mdio_rw),
    .phy_addr(mdio_phy),
    .reg_addr(mdio_reg),
    .wdata   (mdio_wdata),
    .rdata   (mdio_rdata),
    .busy    (mdio_busy),
    .rvalid  (mdio_rvalid),
    .mdc     (eth_mdc),
    .mdio    (eth_mdio)
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

// Expose MDIO line for status print (2-FF sync)
reg mdio_pin_s0, mdio_pin_s1;
always @(posedge clk) begin
    mdio_pin_s0 <= eth_mdio;
    mdio_pin_s1 <= mdio_pin_s0;
end
wire mdio_pin_level = mdio_pin_s1;

// ============================================================
// 1 Hz tick + uptime seconds counter
// ============================================================
reg [26:0] sec_cnt = 27'd0;
reg [15:0] uptime  = 16'd0;
wire tick_1hz = (sec_cnt == 27'd125_000_000 - 1);
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
    .CLK_FREQ (125_000_000),
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
// Message emitter — print one full status line per second,
// triggered by mdio_rvalid pulse. Line is PRE-COMPUTED into a
// 58-byte register array when the read completes; emitter simply
// indexes the array → no giant combinational mux → timing closes.
//
// Format (58 bytes incl CRLF):
//   "t=XXXX rst=X pll=X prst=X mdio=X phy=XX reg=XX val=XXXX\r\n"
// ============================================================
localparam integer LINE_LEN = 58;
reg [7:0]  line_buf [0:LINE_LEN-1];
reg [5:0]  tx_idx     = 6'd0;
reg        tx_active  = 1'b0;

function [7:0] nib_hex;
    input [3:0] n;
    nib_hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
endfunction

// Uptime displayed as 4 hex digits (0000..FFFF = up to ~18 hours)
// — avoids division/modulo that would blow up timing.

always @(posedge clk) begin
    if (rst) begin
        tx_idx    <= 6'd0;
        tx_active <= 1'b0;
    end else if (!tx_active && mdio_rvalid) begin
        // Pre-fill entire line in parallel — each slot is a single-cycle
        // register assignment, no deep mux to the UART output register.
        line_buf[0]  <= "t";
        line_buf[1]  <= "=";
        line_buf[2]  <= nib_hex(uptime[15:12]);
        line_buf[3]  <= nib_hex(uptime[11:8]);
        line_buf[4]  <= nib_hex(uptime[7:4]);
        line_buf[5]  <= nib_hex(uptime[3:0]);
        line_buf[6]  <= " ";
        line_buf[7]  <= "r";
        line_buf[8]  <= "s";
        line_buf[9]  <= "t";
        line_buf[10] <= "=";
        line_buf[11] <= rst ? "1" : "0";
        line_buf[12] <= " ";
        line_buf[13] <= "p";
        line_buf[14] <= "l";
        line_buf[15] <= "l";
        line_buf[16] <= "=";
        line_buf[17] <= pll_locked ? "1" : "0";
        line_buf[18] <= " ";
        line_buf[19] <= "p";
        line_buf[20] <= "r";
        line_buf[21] <= "s";
        line_buf[22] <= "t";
        line_buf[23] <= "=";
        line_buf[24] <= phy_rst_n_reg ? "1" : "0";
        line_buf[25] <= " ";
        line_buf[26] <= "m";
        line_buf[27] <= "d";
        line_buf[28] <= "i";
        line_buf[29] <= "o";
        line_buf[30] <= "=";
        line_buf[31] <= mdio_pin_level ? "1" : "0";
        line_buf[32] <= " ";
        line_buf[33] <= "p";
        line_buf[34] <= "h";
        line_buf[35] <= "y";
        line_buf[36] <= "=";
        line_buf[37] <= nib_hex({3'd0, mdio_phy[4]});
        line_buf[38] <= nib_hex(mdio_phy[3:0]);
        line_buf[39] <= " ";
        line_buf[40] <= "r";
        line_buf[41] <= "e";
        line_buf[42] <= "g";
        line_buf[43] <= "=";
        line_buf[44] <= nib_hex({3'd0, mdio_reg[4]});
        line_buf[45] <= nib_hex(mdio_reg[3:0]);
        line_buf[46] <= " ";
        line_buf[47] <= "v";
        line_buf[48] <= "a";
        line_buf[49] <= "l";
        line_buf[50] <= "=";
        line_buf[51] <= nib_hex(mdio_rdata[15:12]);
        line_buf[52] <= nib_hex(mdio_rdata[11:8]);
        line_buf[53] <= nib_hex(mdio_rdata[7:4]);
        line_buf[54] <= nib_hex(mdio_rdata[3:0]);
        line_buf[55] <= 8'h0D;  // \r
        line_buf[56] <= 8'h0A;  // \n
        line_buf[57] <= 8'h00;  // pad
        tx_idx       <= 6'd0;
        tx_active    <= 1'b1;
    end else if (tx_active && !uart_busy && !uart_wr_en) begin
        uart_wr_d  <= line_buf[tx_idx];
        uart_wr_en <= 1'b1;
    end else if (uart_wr_en) begin
        uart_wr_en <= 1'b0;
        if (tx_idx == 6'd56) tx_active <= 1'b0;
        else                 tx_idx    <= tx_idx + 6'd1;
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
