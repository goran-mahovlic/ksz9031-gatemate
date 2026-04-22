/*
 * fpga_phase2.v
 *
 * PHASE 2 — Ground-truth UART heartbeat.
 *
 * Design intent:
 *   - PLL: 25 MHz → 125 MHz
 *   - reset_sync generates sync-release reset aligned to clk_125
 *   - UART TX only (115200 baud) emits "H\r\n" every 1s
 *   - PHY held in reset (eth_rst_n = 0) — no Ethernet activity
 *   - LEDs:
 *       [0] PLL locked
 *       [1] blink_25 (clock heartbeat — toggles ~3 Hz from clk_125)
 *       [2] UART tx active
 *       [3] heartbeat pulse (fires once per sec)
 *       [7:4] 1 when rst_sync=0 (system running)
 *
 * If after flashing + 20s settle, UART shows 'H' on /dev/ttyACM0 or
 * /dev/ttyACM1 — clock + reset + UART are ALL PROVEN WORKING.
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

    // Ethernet pins — held at safe values, PHY kept in reset
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

// ============================================================
// PLL: 25 MHz → 125 MHz (0°) + 125 MHz (90°)
// ============================================================
wire clk_125;
wire clk_125_90;
wire pll_locked;

pll pll_inst (
    .clock_in(clk_25mhz),
    .clock_5x_out(clk_125),
    .clock_5x_90_out(clk_125_90),
    .lock_out(pll_locked)
);

// ============================================================
// Reset — async-assert, sync-release
// ============================================================
// Async-low reset source: PLL locked AND btn[2] (active-low) not pressed
wire async_rst_n = pll_locked;

wire rst_sync; // active-high, synchronous to clk_125
reset_sync rst_sync_inst (
    .clk(clk_125),
    .async_rst_n(async_rst_n),
    .rst_sync(rst_sync)
);

// ============================================================
// UART TX heartbeat
// ============================================================
wire       tx_busy;
wire [7:0] hb_tx_data;
wire       hb_tx_ena;
wire       hb_pulse;

uart_heartbeat #(
    .CLK_FREQ(125_000_000),
    .PERIOD_S(1)
) hb_inst (
    .clk(clk_125),
    .rst(rst_sync),
    .tx_busy(tx_busy),
    .tx_data(hb_tx_data),
    .tx_ena(hb_tx_ena),
    .hb_pulse(hb_pulse)
);

uart #(
    .CLK_FREQ(125_000_000),
    .BAUD_RATE(115_200)
) uart_inst (
    .clk(clk_125),
    .rst(rst_sync),
    .tx_ena(hb_tx_ena),
    .tx_data(hb_tx_data),
    .tx_busy(tx_busy),
    .tx(uart_tx),
    .rx(uart_rx),
    .rx_busy(),
    .rx_error(),
    .rx_data()
);

// ============================================================
// LEDs — diagnostic
// ============================================================
reg [24:0] blink_cnt;
always @(posedge clk_125) begin
    if (rst_sync)
        blink_cnt <= 25'd0;
    else
        blink_cnt <= blink_cnt + 1'b1;
end

// Stretch the heartbeat pulse so it is visibly long on the LED (~134 ms)
reg [23:0] hb_led_cnt;
always @(posedge clk_125) begin
    if (rst_sync)
        hb_led_cnt <= 24'd0;
    else if (hb_pulse)
        hb_led_cnt <= 24'hFFFFFF;
    else if (hb_led_cnt != 0)
        hb_led_cnt <= hb_led_cnt - 1'b1;
end

assign led[0] = pll_locked;
assign led[1] = blink_cnt[24];
assign led[2] = tx_busy;
assign led[3] = (hb_led_cnt != 0);
assign led[4] = ~rst_sync;
assign led[5] = ~rst_sync;
assign led[6] = ~rst_sync;
assign led[7] = ~rst_sync;

// ============================================================
// Keep PHY in reset, drive RGMII outputs inert
// ============================================================
assign eth_rst_n  = 1'b0;   // hold PHY in reset
assign eth_tx_clk = 1'b0;
assign eth_txd    = 4'b0000;
assign eth_tx_ctl = 1'b0;
assign eth_mdc    = 1'b0;
// eth_mdio is inout; leave hi-Z by not driving — the tri-state below:
assign eth_mdio   = 1'bz;

// Keep rx signals in use to suppress "unused" warnings
wire _unused = &{1'b0, eth_rx_clk, eth_rxd, eth_rx_ctl, clk_125_90, btn[2:0], 1'b0};

endmodule

`resetall
