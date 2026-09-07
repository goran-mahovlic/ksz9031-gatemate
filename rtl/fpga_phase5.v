/*
 * fpga_phase5.v — Phase 4 structure + integrated UART-ILA.
 *
 * The previous plain-English 1 Hz UART emitter is replaced by a UART-ILA that
 * captures key MDIO/MDC signals on every MDIO transaction and dumps them as
 * hex ASCII over the same UART pin.
 *
 * Probe word packing (16 bits):
 *   [0]   mdio_pad         — raw MDIO pad (2-FF synced)
 *   [1]   mdio_out         — what the FPGA wants to drive
 *   [2]   mdio_oe          — 1=FPGA drives, 0=Hi-Z
 *   [3]   mdc              — MDC clock to PHY
 *   [4]   busy             — mdio_controller is in a transaction
 *   [5]   rvalid           — one-cycle read-complete pulse
 *   [6]   mdio_start       — request to start transaction
 *   [7]   phy_ready        — PHY reset released
 *   [11:8]  state[3:0]     — mdio_controller FSM state
 *   [15:12] bit_cnt[3:0]   — mdio_controller bit counter (low 4 bits)
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

// --- Unused RGMII outputs ---
assign eth_tx_clk = 1'b0;
assign eth_txd    = 4'd0;
assign eth_tx_ctl = 1'b0;

// ============================================================
// Clocking — 50 MHz PLL. Enough for 2.5 MHz MDC + 115200 baud UART,
// and gives timing headroom for the UART-ILA BRAM path on GateMate.
// ============================================================
wire clk_50, pll_locked;
pll_50mhz pll_inst (
    .clock_in (clk_25mhz),
    .clock_out(clk_50),
    .lock_out (pll_locked)
);
wire clk = clk_50;

// ============================================================
// Reset
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

// PHY reset — hold low ~33 ms
reg [21:0] phy_rst_cnt   = 22'h3FFFFF;
reg        phy_rst_n_reg = 1'b0;
always @(posedge clk) begin
    if (!phy_rst_n_reg) begin
        if (phy_rst_cnt == 22'd0) phy_rst_n_reg <= 1'b1;
        else                      phy_rst_cnt   <= phy_rst_cnt - 22'd1;
    end
end
assign eth_rst_n = phy_rst_n_reg;
wire phy_ready = phy_rst_n_reg;

// ============================================================
// MDIO controller — IO pad lives here at top, controller exposes 3 signals.
// Workaround for nextpnr-himbaechel pack_io.cc bug: when T is a constant,
// the OE LUT (CPE INIT_L11 = LUT_INV_D0) is paired with a disconnected D0
// input → OE is permanently 1 → FPGA always drives the pad. Driving T
// from a real register-derived net avoids that code path entirely.
// ============================================================
reg         mdio_start  = 1'b0;
reg         mdio_rw     = 1'b1;
reg  [4:0]  mdio_phy    = 5'd0;
reg  [4:0]  mdio_reg    = 5'd2;
reg  [15:0] mdio_wdata  = 16'd0;
wire [15:0] mdio_rdata;
wire        mdio_busy;
wire        mdio_rvalid;

wire        mdio_o_w;
wire        mdio_oe_w;
wire        mdio_i_w;

wire [3:0]  mdio_dbg_state;
wire [4:0]  mdio_dbg_bit_cnt;
wire        mdio_dbg_out;
wire        mdio_dbg_oe;
wire        mdio_dbg_in;

mdio_controller #(
    .SYS_CLK_FREQ(50_000_000),
    .MDC_FREQ    (2_500_000)
) mdio_ctrl_inst (
    .clk         (clk),
    .rst         (rst),
    .start       (mdio_start),
    .rw          (mdio_rw),
    .phy_addr    (mdio_phy),
    .reg_addr    (mdio_reg),
    .wdata       (mdio_wdata),
    .rdata       (mdio_rdata),
    .busy        (mdio_busy),
    .rvalid      (mdio_rvalid),
    .mdc         (eth_mdc),
    .mdio_o      (mdio_o_w),
    .mdio_oe     (mdio_oe_w),
    .mdio_i      (mdio_i_w),
    .dbg_state   (mdio_dbg_state),
    .dbg_bit_cnt (mdio_dbg_bit_cnt),
    .dbg_mdio_out(mdio_dbg_out),
    .dbg_mdio_oe (mdio_dbg_oe),
    .dbg_mdio_in (mdio_dbg_in)
);

// Explicit CC_IOBUF — T derived from a register-driven net so the packer
// takes the non-constant code path (INIT_L11 = LUT_D0, INIT_L02 = LUT_INV_D0).
// CC_IOBUF semantics per cells_sim.v: T=1 → Hi-Z, T=0 → drive A.
(* keep *) wire mdio_t_w = ~mdio_oe_w;

(* keep *) CC_IOBUF #(
    .PIN_NAME("UNPLACED")
) mdio_iobuf_inst (
    .A (mdio_o_w),
    .T (mdio_t_w),
    .Y (mdio_i_w),
    .IO(eth_mdio)
);

// Latch last read (for LEDs only)
reg [15:0] last_val    = 16'hDEAD;
reg        last_rvalid = 1'b0;
always @(posedge clk) begin
    if (rst) begin
        last_val    <= 16'hDEAD;
        last_rvalid <= 1'b0;
    end else if (mdio_rvalid) begin
        last_val    <= mdio_rdata;
        last_rvalid <= 1'b1;
    end
end

// ============================================================
// 1 Hz tick + register cycle
// ============================================================
reg [25:0] sec_cnt = 26'd0;
wire tick_1hz = (sec_cnt == 26'd50_000_000 - 1);
always @(posedge clk) begin
    if (rst)           sec_cnt <= 26'd0;
    else if (tick_1hz) sec_cnt <= 26'd0;
    else               sec_cnt <= sec_cnt + 26'd1;
end

// PHY address scan: sweep PHY addr 0..31, reading reg 2 (PHY ID1).
// One transaction every ~150 ms so we cycle all 32 addrs in ~5 seconds.
// The ILA dump per trigger is ~90 ms, leaving ~60 ms idle per transaction.
reg [18:0] fast_cnt = 19'd0;
wire fast_tick = (fast_cnt == 19'd7_500_000 - 1);  // 150 ms at 50 MHz
always @(posedge clk) begin
    if (rst)            fast_cnt <= 19'd0;
    else if (fast_tick) fast_cnt <= 19'd0;
    else                fast_cnt <= fast_cnt + 19'd1;
end

always @(posedge clk) begin
    if (rst) begin
        mdio_start <= 1'b0;
        mdio_rw    <= 1'b1;
        mdio_phy   <= 5'd0;
        mdio_reg   <= 5'd2;     // PHY ID1 — expected 0x0022 on KSZ9031
        mdio_wdata <= 16'd0;
    end else begin
        if (fast_tick && phy_ready && !mdio_busy && !mdio_start) begin
            mdio_rw    <= 1'b1;
            mdio_reg   <= 5'd2;
            mdio_start <= 1'b1;
        end else if (mdio_start) begin
            mdio_start <= 1'b0;
        end
        // Advance PHY addr at end of each transaction (rvalid pulse)
        if (mdio_rvalid)
            mdio_phy <= mdio_phy + 5'd1;  // wraps 0..31
    end
end

// ============================================================
// UART
// ============================================================
wire       uart_busy;
wire [7:0] uart_wr_d;
wire       uart_wr_en;

uart #(
    .CLK_FREQ (50_000_000),
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
// UART-ILA: capture + dump MDIO signals
// ============================================================
wire [15:0] probe = {
    mdio_dbg_bit_cnt[3:0],  // [15:12]
    mdio_dbg_state,         // [11:8]
    phy_ready,              // [7]
    mdio_start,             // [6]
    mdio_rvalid,            // [5]
    mdio_busy,              // [4]
    eth_mdc,                // [3]
    mdio_dbg_oe,            // [2]
    mdio_dbg_out,           // [1]
    mdio_dbg_in             // [0]
};

uart_ila #(
    .SAMPLE_WIDTH(16),
    .BUF_DEPTH   (128),
    .ADDR_WIDTH  (7),
    .SAMPLE_DIV  (10)        // 50 MHz / 10 = 5 MHz sample rate → 25.6 µs window
) ila_inst (
    .clk     (clk),
    .rst     (rst),
    .probe   (probe),
    .trigger (mdio_start),   // trigger on rising edge of mdio_start
    .tx_data (uart_wr_d),
    .tx_ena  (uart_wr_en),
    .tx_busy (uart_busy)
);

// ============================================================
// LEDs
// ============================================================
assign led[0] = sec_cnt[26];         // slow blink
assign led[1] = phy_rst_n_reg;
assign led[2] = last_rvalid;
assign led[3] = (last_val != 16'hDEAD) && (last_val != 16'h0000);
assign led[4] = pll_locked;
assign led[5] = mdio_dbg_in;
assign led[6] = uart_busy;
assign led[7] = rst;

endmodule

`resetall
