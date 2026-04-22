/*
 * fpga_phase3.v — REDESIGNED 2026-04-22 pass 4
 *
 * MINIMAL MDIO diagnostic:
 *   - Prints state_dbg as a single hex digit followed by space, whenever
 *     state changes. Example stream: "0 1 2 3 4 5 6 3 4 5 6 3 ... "
 *   - Every 1s also prints full phy_id as 4 hex digits + newline:
 *       "P=0022\r\n" — or "P=0000\r\n" if no PHY found.
 *   - Also prints scan address every time a scan read starts: "S=14\r\n"
 *
 * Keeps combinational paths trivial — a single small mux per output.
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

    // Ethernet — RGMII held inert, only MDIO active
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

// PLL 25 -> 125 MHz (used only for pll_locked signal; Phase 3 logic runs at 25 MHz directly)
wire clk_125, clk_125_90, pll_locked;
pll pll_inst (
    .clock_in(clk_25mhz),
    .clock_5x_out(clk_125),
    .clock_5x_90_out(clk_125_90),
    .lock_out(pll_locked)
);

wire clk_sys = clk_25mhz;

// Reset only from PLL locked — don't depend on btn (could be floating)
wire async_rst_n = pll_locked;
wire rst_sync;
reset_sync rst_sync_inst (
    .clk(clk_sys),
    .async_rst_n(async_rst_n),
    .rst_sync(rst_sync)
);

// PHY reset — hold for ~100ms
reg [23:0] phy_rst_cnt;
reg        phy_rst_release;
always @(posedge clk_sys) begin
    if (rst_sync) begin
        phy_rst_cnt     <= 24'd0;
        phy_rst_release <= 1'b0;
    end else if (phy_rst_cnt == 24'd2_500_000) begin  // 100 ms @ 25 MHz
        phy_rst_release <= 1'b1;
    end else begin
        phy_rst_cnt <= phy_rst_cnt + 1'b1;
    end
end
assign eth_rst_n = phy_rst_release;

// MDIO controller
wire        mdio_start;
wire        mdio_rw;
wire [4:0]  mdio_phy;
wire [4:0]  mdio_reg;
wire [15:0] mdio_wdata;
wire [15:0] mdio_rdata;
wire        mdio_busy;
wire        mdio_rvalid;
mdio_controller #(
    .SYS_CLK_FREQ(25_000_000),
    .MDC_FREQ(2_500_000)
) mdio_ctrl_inst (
    .clk(clk_sys),
    .rst(rst_sync),
    .start(mdio_start),
    .rw(mdio_rw),
    .phy_addr(mdio_phy),
    .reg_addr(mdio_reg),
    .wdata(mdio_wdata),
    .rdata(mdio_rdata),
    .busy(mdio_busy),
    .rvalid(mdio_rvalid),
    .mdc(eth_mdc),
    .mdio(eth_mdio)
);

// MDIO init FSM
wire        init_done;
wire        init_error;
wire [15:0] phy_id;
wire [4:0]  phy_addr_found;
wire [4:0]  mdio_state_dbg;
mdio_init #(
    .SETTLE_CYCLES(23'd1_250_000),  // 50 ms @ 25 MHz
    .RETRY_CYCLES (23'd250_000)     // 10 ms @ 25 MHz
) mdio_init_inst (
    .clk(clk_sys),
    .rst(rst_sync),
    .phy_ready(phy_rst_release),
    .mdio_start(mdio_start),
    .mdio_rw(mdio_rw),
    .mdio_phy(mdio_phy),
    .mdio_reg(mdio_reg),
    .mdio_wdata(mdio_wdata),
    .mdio_rdata(mdio_rdata),
    .mdio_busy(mdio_busy),
    .mdio_rvalid(mdio_rvalid),
    .init_done(init_done),
    .init_error(init_error),
    .phy_id(phy_id),
    .phy_addr_found(phy_addr_found),
    .state_dbg(mdio_state_dbg)
);

// ============================================================
// Byte stream builder — we write bytes one at a time into a
// simple 64-deep FIFO that feeds a UART TX.
// ============================================================

// FIFO: single-producer, UART-TX drains it
reg [7:0] fifo_mem [0:63];
reg [6:0] fifo_wptr, fifo_rptr;
wire fifo_empty = (fifo_wptr == fifo_rptr);
wire fifo_full  = ((fifo_wptr[5:0] == fifo_rptr[5:0]) &&
                   (fifo_wptr[6]   != fifo_rptr[6]));

// Write interface
reg  [7:0] wr_byte;
reg        wr_en;

always @(posedge clk_sys) begin
    if (rst_sync) begin
        fifo_wptr <= 0;
    end else if (wr_en && !fifo_full) begin
        fifo_mem[fifo_wptr[5:0]] <= wr_byte;
        fifo_wptr <= fifo_wptr + 1'b1;
    end
end

// UART TX draining the FIFO
reg  [7:0] tx_data_reg;
reg        tx_ena_reg;
wire       tx_busy;

uart #(
    .CLK_FREQ(25_000_000),
    .BAUD_RATE(115_200)
) uart_inst (
    .clk(clk_sys),
    .rst(rst_sync),
    .tx_ena(tx_ena_reg),
    .tx_data(tx_data_reg),
    .tx_busy(tx_busy),
    .tx(uart_tx),
    .rx(uart_rx),
    .rx_busy(),
    .rx_error(),
    .rx_data()
);

reg [1:0] drain_state;
localparam D_IDLE = 2'd0;
localparam D_PUSH = 2'd1;
localparam D_WAIT = 2'd2;
always @(posedge clk_sys) begin
    if (rst_sync) begin
        drain_state <= D_IDLE;
        tx_ena_reg  <= 1'b0;
        tx_data_reg <= 8'd0;
        fifo_rptr   <= 0;
    end else begin
        tx_ena_reg <= 1'b0;
        case (drain_state)
            D_IDLE: begin
                if (!fifo_empty && !tx_busy) begin
                    tx_data_reg <= fifo_mem[fifo_rptr[5:0]];
                    tx_ena_reg  <= 1'b1;
                    fifo_rptr   <= fifo_rptr + 1'b1;
                    drain_state <= D_PUSH;
                end
            end
            D_PUSH: if (tx_busy)  drain_state <= D_WAIT;
            D_WAIT: if (!tx_busy) drain_state <= D_IDLE;
            default: drain_state <= D_IDLE;
        endcase
    end
end

// ============================================================
// Event emitter (simple sequential writer)
// ============================================================
//   1) On state change of mdio_state_dbg: emit hex(state) + ' '
//   2) Every 1s: emit "P=<id_hex>\r\n"
//   3) Every 1s: emit "A=<addr_found_hex>\r\n"
//   4) Boot (10ms after reset): emit "\r\nBOOT\r\n"

// Hex helper (combinational)
function [7:0] nib2hex;
    input [3:0] n;
    begin
        nib2hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
    end
endfunction

// State change detection
reg [4:0] state_prev;
always @(posedge clk_sys) begin
    if (rst_sync) state_prev <= 5'd31;
    else          state_prev <= mdio_state_dbg;
end
wire state_changed = (mdio_state_dbg != state_prev);

// 1Hz tick
reg [26:0] hb_cnt;
reg        hb_tick;
always @(posedge clk_sys) begin
    if (rst_sync) begin
        hb_cnt  <= 27'd0;
        hb_tick <= 1'b0;
    end else if (hb_cnt == 27'd24_999_999) begin  // 1 Hz @ 25 MHz
        hb_cnt  <= 27'd0;
        hb_tick <= 1'b1;
    end else begin
        hb_cnt  <= hb_cnt + 1'b1;
        hb_tick <= 1'b0;
    end
end

// Boot pulse
reg [23:0] boot_cnt;
reg        boot_pulse;
reg        boot_done_r;
always @(posedge clk_sys) begin
    if (rst_sync) begin
        boot_cnt    <= 24'd0;
        boot_pulse  <= 1'b0;
        boot_done_r <= 1'b0;
    end else begin
        boot_pulse <= 1'b0;
        if (!boot_done_r) begin
            if (boot_cnt == 24'd250_000) begin  // 10 ms @ 25 MHz
                boot_pulse  <= 1'b1;
                boot_done_r <= 1'b1;
            end else begin
                boot_cnt <= boot_cnt + 1'b1;
            end
        end
    end
end

// ============================================================
// Simple sequential writer — walks through a fixed character
// sequence when a trigger fires. Latches the snapshot values at
// trigger time so the output is stable.
// ============================================================
reg [4:0]  w_state;
reg [5:0]  w_idx;
reg [3:0]  w_kind;   // 0=boot, 1=state, 2=phy_id, 3=addr
reg [15:0] w_snap_id;
reg [4:0]  w_snap_state;
reg [4:0]  w_snap_addr;

localparam W_IDLE  = 5'd0;
localparam W_EMIT  = 5'd1;

localparam K_BOOT  = 4'd0;
localparam K_STATE = 4'd1;
localparam K_PHYID = 4'd2;
localparam K_ADDR  = 4'd3;

// Priority: boot > state_changed > hb_tick (which triggers PHYID every 2nd, ADDR every 1st)
reg hb_toggle;
always @(posedge clk_sys) begin
    if (rst_sync) hb_toggle <= 1'b0;
    else if (hb_tick) hb_toggle <= ~hb_toggle;
end

// Length per kind
function [5:0] w_len;
    input [3:0] k;
    case (k)
        K_BOOT:  w_len = 6'd8;  // "\r\nBOOT\r\n"
        K_STATE: w_len = 6'd2;  // "X "
        K_PHYID: w_len = 6'd9;  // "P=XXXX\r\n"
        K_ADDR:  w_len = 6'd6;  // "A=XX\r\n"
        default: w_len = 6'd0;
    endcase
endfunction

// Character at position
function [7:0] w_char;
    input [3:0] k;
    input [5:0] i;
    input [15:0] snap_id;
    input [4:0]  snap_state;
    input [4:0]  snap_addr;
    case (k)
        K_BOOT: case (i)
            6'd0: w_char = 8'h0D;
            6'd1: w_char = 8'h0A;
            6'd2: w_char = "B";
            6'd3: w_char = "O";
            6'd4: w_char = "O";
            6'd5: w_char = "T";
            6'd6: w_char = 8'h0D;
            6'd7: w_char = 8'h0A;
            default: w_char = " ";
        endcase
        K_STATE: case (i)
            6'd0: w_char = nib2hex({3'b0, snap_state[4] | snap_state[3]} + {3'b0, snap_state[4]});
            6'd1: w_char = " ";
            default: w_char = " ";
        endcase
        K_PHYID: case (i)
            6'd0: w_char = "P";
            6'd1: w_char = "=";
            6'd2: w_char = nib2hex(snap_id[15:12]);
            6'd3: w_char = nib2hex(snap_id[11:8]);
            6'd4: w_char = nib2hex(snap_id[7:4]);
            6'd5: w_char = nib2hex(snap_id[3:0]);
            6'd6: w_char = 8'h0D;
            6'd7: w_char = 8'h0A;
            default: w_char = " ";
        endcase
        K_ADDR: case (i)
            6'd0: w_char = "A";
            6'd1: w_char = "=";
            6'd2: w_char = nib2hex({3'b0, snap_addr[4]});
            6'd3: w_char = nib2hex({1'b0, snap_addr[3:0]});
            6'd4: w_char = 8'h0D;
            6'd5: w_char = 8'h0A;
            default: w_char = " ";
        endcase
        default: w_char = "?";
    endcase
endfunction

// Event queue: 16 events deep, each (kind, id, state, addr)
reg [3:0]  evq_kind  [0:15];
reg [15:0] evq_id    [0:15];
reg [4:0]  evq_state [0:15];
reg [4:0]  evq_addr  [0:15];
reg [4:0]  evq_wptr, evq_rptr;

wire evq_empty = (evq_wptr == evq_rptr);
wire evq_full  = ((evq_wptr[3:0] == evq_rptr[3:0]) &&
                  (evq_wptr[4]   != evq_rptr[4]));

// Enqueue logic — priority pick
reg        evq_push;
reg [3:0]  evq_push_kind;

always @(*) begin
    evq_push      = 1'b0;
    evq_push_kind = K_BOOT;
    if (boot_pulse)          begin evq_push=1; evq_push_kind=K_BOOT; end
    else if (state_changed)  begin evq_push=1; evq_push_kind=K_STATE; end
    else if (hb_tick && hb_toggle) begin evq_push=1; evq_push_kind=K_PHYID; end
    else if (hb_tick)        begin evq_push=1; evq_push_kind=K_ADDR; end
end

always @(posedge clk_sys) begin
    if (rst_sync) begin
        evq_wptr <= 0;
    end else if (evq_push && !evq_full) begin
        evq_kind [evq_wptr[3:0]] <= evq_push_kind;
        evq_id   [evq_wptr[3:0]] <= phy_id;
        evq_state[evq_wptr[3:0]] <= mdio_state_dbg;
        evq_addr [evq_wptr[3:0]] <= phy_addr_found;
        evq_wptr <= evq_wptr + 1'b1;
    end
end

// Emit FSM — pops event and writes characters one-per-cycle to the UART FIFO
// Simple (no pipeline): w_char is a 4-way case over small cases, timing-safe.
always @(posedge clk_sys) begin
    if (rst_sync) begin
        w_state       <= W_IDLE;
        w_idx         <= 6'd0;
        w_kind        <= 4'd0;
        w_snap_id     <= 16'd0;
        w_snap_state  <= 5'd0;
        w_snap_addr   <= 5'd0;
        wr_byte       <= 8'd0;
        wr_en         <= 1'b0;
        evq_rptr      <= 0;
    end else begin
        wr_en <= 1'b0;
        case (w_state)
            W_IDLE: begin
                if (!evq_empty) begin
                    w_kind        <= evq_kind [evq_rptr[3:0]];
                    w_snap_id     <= evq_id   [evq_rptr[3:0]];
                    w_snap_state  <= evq_state[evq_rptr[3:0]];
                    w_snap_addr   <= evq_addr [evq_rptr[3:0]];
                    w_idx         <= 6'd0;
                    evq_rptr      <= evq_rptr + 1'b1;
                    w_state       <= W_EMIT;
                end
            end
            W_EMIT: begin
                if (!fifo_full) begin
                    wr_byte <= w_char(w_kind, w_idx, w_snap_id, w_snap_state, w_snap_addr);
                    wr_en   <= 1'b1;
                    if (w_idx == w_len(w_kind) - 1) begin
                        w_state <= W_IDLE;
                    end else begin
                        w_idx <= w_idx + 1'b1;
                    end
                end
            end
            default: w_state <= W_IDLE;
        endcase
    end
end

// ============================================================
// LEDs
// ============================================================
reg [24:0] blink_cnt;
always @(posedge clk_sys) begin
    if (rst_sync) blink_cnt <= 25'd0;
    else          blink_cnt <= blink_cnt + 1'b1;
end
assign led[0] = pll_locked;
assign led[1] = blink_cnt[24];
assign led[2] = phy_rst_release;
assign led[3] = init_done;
assign led[4] = init_error;
assign led[5] = mdio_state_dbg[0];
assign led[6] = mdio_state_dbg[1];
assign led[7] = mdio_state_dbg[2];

// RGMII TX inert
assign eth_tx_clk = 1'b0;
assign eth_txd    = 4'b0000;
assign eth_tx_ctl = 1'b0;

wire _unused = &{1'b0, eth_rx_clk, eth_rxd, eth_rx_ctl, clk_125, clk_125_90, btn[2:0], 1'b0};

endmodule

`resetall
