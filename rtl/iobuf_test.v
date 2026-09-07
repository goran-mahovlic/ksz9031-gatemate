/*
 * iobuf_test.v — minimalni manual SET/GET tester za eth_mdio (CC_IOBUF).
 *
 * Cilj: dokazati ili odbaciti je li GateMate silikon poštuje CC_IOBUF.T
 * neovisno od bilo kakvog FSM-a. Korisnik kontrolira pin preko UART-a
 * i čita ga unatrag.
 *
 * Komande (jedan znak + opcionalni CR/LF):
 *   '0'      → SET pad: oe=1, out=0  (drive low)
 *   '1'      → SET pad: oe=1, out=1  (drive high)
 *   'z'/'Z'  → SET pad: oe=0         (Hi-Z, releases line to pull-up)
 *   'r'/'R'  → GET pad: vrati '0' ili '1' (sampled CC_IOBUF.Y)
 *   bilo što → odgovor '?'
 *
 * Odgovor je 3 bajta: <char>\r\n.
 *
 * LED feedback (live):
 *   led[0] = current oe
 *   led[1] = current out
 *   led[2] = current sampled in
 *   led[3] = activity (toggles na svaki primljeni char)
 *   led[4] = pll_locked
 *   led[5] = mdio_in (live, isto kao led[2])
 *   led[6] = uart tx_busy
 *   led[7] = rst
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

// Unused outputs (driven low)
assign eth_tx_clk = 1'b0;
assign eth_txd    = 4'd0;
assign eth_tx_ctl = 1'b0;

// Free-running MDC at 2.5 MHz (50 MHz / 20).  We never start a real
// MDIO transaction in this test — line stays Hi-Z — but the clock is
// alive so we can see whether the PHY reacts to MDC edges by driving
// the line low (which would explain phase5's stuck-low DATA samples).
reg [4:0] mdc_div = 5'd0;
reg       mdc_reg = 1'b0;
always @(posedge clk) begin
    if (rst) begin
        mdc_div <= 5'd0;
        mdc_reg <= 1'b0;
    end else if (mdc_div == 5'd9) begin
        mdc_div <= 5'd0;
        mdc_reg <= ~mdc_reg;
    end else begin
        mdc_div <= mdc_div + 5'd1;
    end
end
assign eth_mdc = mdc_reg;
// PHY reset is driven by phase cycler below — alternates so we can see
// whether the PHY drives MDIO when out of reset.

// ----------- Clocking -----------
wire clk_50, pll_locked;
pll_50mhz pll_inst (
    .clock_in (clk_25mhz),
    .clock_out(clk_50),
    .lock_out (pll_locked)
);
wire clk = clk_50;

// ----------- Reset -----------
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

// ----------- UART -----------
wire        uart_tx_ena;
wire [7:0]  uart_tx_data;
wire        uart_tx_busy;
wire        uart_rx_busy;
wire        uart_rx_error;
wire [7:0]  uart_rx_data;

uart #(
    .CLK_FREQ (50_000_000),
    .BAUD_RATE(115_200)
) uart_inst (
    .clk     (clk),
    .rst     (rst),
    .tx_ena  (uart_tx_ena),
    .tx_data (uart_tx_data),
    .tx_busy (uart_tx_busy),
    .tx      (uart_tx),
    .rx      (uart_rx),
    .rx_busy (uart_rx_busy),
    .rx_error(uart_rx_error),
    .rx_data (uart_rx_data)
);

// Detect rx_busy falling edge → new byte arrived
reg rx_busy_d = 1'b0;
always @(posedge clk) rx_busy_d <= uart_rx_busy;
wire rx_strobe = rx_busy_d & ~uart_rx_busy & ~uart_rx_error;

// ----------- IOBUF under test -----------
(* keep *) reg  oe_reg  = 1'b0;     // start in Hi-Z
(* keep *) reg  out_reg = 1'b0;
(* keep *) wire mdio_y_w;

// CC_IOBUF semantics: T=1 → Hi-Z, T=0 → drive A
// Use ~oe so T is driven from a real net, not a constant; avoids pack_io.cc
// constant-T bug (LUT_INV_D0 with disconnected D0 → permanent OE).
(* keep *) wire mdio_t_w = ~oe_reg;

(* keep *) CC_IOBUF #(
    .PIN_NAME("UNPLACED")
) iobuf_inst (
    .A (out_reg),
    .T (mdio_t_w),
    .Y (mdio_y_w),
    .IO(eth_mdio)
);

// 2-FF synchronizer on Y (just in case)
reg s0 = 1'b0, s1 = 1'b0;
always @(posedge clk) begin
    s0 <= mdio_y_w;
    s1 <= s0;
end
wire mdio_in = s1;

// ----------- Live status emitter -----------
// Every ~250ms, emit "OE=<e> OUT=<o> T=<t> IN=<i>\r\n" so we can watch
// the live IO state and confirm what commands do.
//
// Commands ('0','1','z','Z') still update oe/out and we observe the
// effect via the next status line.

// Snapshot the state we'll print, so all 6 fields belong to the same tick.
reg [7:0] tx_buf [0:39];
localparam BUF_LEN = 40;
reg [5:0] tx_idx = 6'd40;     // 40 = idle
reg       tx_ena_r  = 1'b0;
reg [7:0] tx_data_r = 8'h00;

reg [23:0] hb_cnt = 24'd0;
wire       hb_tick = (hb_cnt == 24'd12_500_000 - 1);  // 250 ms @ 50 MHz
always @(posedge clk) begin
    if (rst)            hb_cnt <= 24'd0;
    else if (hb_tick)   hb_cnt <= 24'd0;
    else                hb_cnt <= hb_cnt + 24'd1;
end

// Self-running phase cycler — back to a 4-phase loop with the PHY held
// in reset (the FIRST configuration that worked).  The 8-phase variant
// produced a different placement and the toolchain regressed: even with
// a real T net, the OE LUT routing was such that the FPGA drove the pad
// permanently.  Lesson: this workaround is sensitive to placement, so
// keep the design minimal and re-verify after every structural change.
//
//   PH=0: oe=0          → predicted IN=1 (Hi-Z + external pull-up)
//   PH=1: oe=1, out=0   → predicted IN=0 (FPGA drives 0)
//   PH=2: oe=1, out=1   → predicted IN=1 (FPGA drives 1)
//   PH=3: oe=0          → predicted IN=1 (back to Hi-Z, sanity)
// Hold PHY in reset for ~50 ms after FPGA reset, then release.
// This lets the PHY actually run while we still cycle FPGA tristate
// states.  Goal: see whether the PHY drives MDIO when it should be idle.
reg [21:0] phy_rst_cnt = 22'h3FFFFF;  // ~84 ms @ 50 MHz
reg        phy_rst_n_reg = 1'b0;
always @(posedge clk) begin
    if (rst) begin
        phy_rst_cnt   <= 22'h3FFFFF;
        phy_rst_n_reg <= 1'b0;
    end else if (!phy_rst_n_reg) begin
        if (phy_rst_cnt == 22'd0) phy_rst_n_reg <= 1'b1;
        else                      phy_rst_cnt   <= phy_rst_cnt - 22'd1;
    end
end
assign eth_rst_n = phy_rst_n_reg;

reg [25:0] ph_cnt = 26'd0;
reg [1:0]  phase  = 2'd0;
localparam PHASE_TICKS = 26'd75_000_000;   // 1.5 s @ 50 MHz

always @(posedge clk) begin
    if (rst) begin
        ph_cnt <= 26'd0;
        phase  <= 2'd0;
    end else if (ph_cnt == PHASE_TICKS - 1) begin
        ph_cnt <= 26'd0;
        phase  <= phase + 2'd1;
    end else begin
        ph_cnt <= ph_cnt + 26'd1;
    end
end

always @(posedge clk) begin
    if (rst) begin
        oe_reg  <= 1'b0;
        out_reg <= 1'b0;
    end else begin
        case (phase)
            2'd0: begin oe_reg <= 1'b0; out_reg <= 1'b0; end
            2'd1: begin oe_reg <= 1'b1; out_reg <= 1'b0; end
            2'd2: begin oe_reg <= 1'b1; out_reg <= 1'b1; end
            2'd3: begin oe_reg <= 1'b0; out_reg <= 1'b0; end
        endcase
    end
end

// Activity LED: toggle on each byte received
reg activity = 1'b0;
reg [7:0] rx_last  = 8'h00;
reg [7:0] rx_count = 8'h00;
always @(posedge clk) begin
    if (rst) begin
        activity <= 1'b0;
        rx_last  <= 8'h00;
        rx_count <= 8'h00;
    end else if (rx_strobe) begin
        activity <= ~activity;
        rx_last  <= uart_rx_data;
        rx_count <= rx_count + 8'd1;
    end
end

// Hex helpers
function [7:0] nib_hex; input [3:0] n;
    nib_hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
endfunction

// Format and emit status line on each hb_tick.
// Buffer: "OE=x OUT=x T=x IN=x\r\n" = 22 chars; padded to 24.
integer k;
always @(posedge clk) begin
    if (rst) begin
        tx_idx     <= 6'd40;
        tx_ena_r   <= 1'b0;
        tx_data_r  <= 8'h00;
        for (k = 0; k < BUF_LEN; k = k + 1) tx_buf[k] <= 8'h20;
    end else begin
        tx_ena_r <= 1'b0;
        if (hb_tick && tx_idx == 6'd40) begin
            // "PH=x OE=x OUT=x T=x IN=x\r\n"  (26 chars)
            tx_buf[0]  <= "P"; tx_buf[1] <= "H"; tx_buf[2] <= "=";
            tx_buf[3]  <= 8'h30 + {6'd0, phase};
            tx_buf[4]  <= " ";
            tx_buf[5]  <= "O"; tx_buf[6] <= "E"; tx_buf[7] <= "=";
            tx_buf[8]  <= oe_reg ? "1" : "0";
            tx_buf[9]  <= " ";
            tx_buf[10] <= "O"; tx_buf[11] <= "U"; tx_buf[12] <= "T"; tx_buf[13] <= "=";
            tx_buf[14] <= out_reg ? "1" : "0";
            tx_buf[15] <= " ";
            tx_buf[16] <= "T"; tx_buf[17] <= "=";
            tx_buf[18] <= mdio_t_w ? "1" : "0";
            tx_buf[19] <= " ";
            tx_buf[20] <= "I"; tx_buf[21] <= "N"; tx_buf[22] <= "=";
            tx_buf[23] <= mdio_in ? "1" : "0";
            tx_buf[24] <= 8'h0D; // \r
            tx_buf[25] <= 8'h0A; // \n
            tx_idx <= 6'd0;
        end else if (tx_idx < 6'd26 && !uart_tx_busy && !tx_ena_r) begin
            tx_data_r <= tx_buf[tx_idx];
            tx_ena_r  <= 1'b1;
            tx_idx    <= tx_idx + 6'd1;
        end else if (tx_idx == 6'd26 && !uart_tx_busy && !tx_ena_r) begin
            tx_idx <= 6'd40; // done
        end
    end
end

assign uart_tx_ena  = tx_ena_r;
assign uart_tx_data = tx_data_r;

// ----------- LEDs -----------
assign led[0] = oe_reg;
assign led[1] = out_reg;
assign led[2] = mdio_in;
assign led[3] = activity;
assign led[4] = pll_locked;
assign led[5] = mdio_in;
assign led[6] = uart_tx_busy;
assign led[7] = rst;

endmodule

`resetall
