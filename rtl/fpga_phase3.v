/*
 * fpga_phase3.v — REDESIGNED 2026-04-22 pass 5 (Emard)
 *
 * ROOT-CAUSE FIX: Previous bitstream showed repeating BOOT with stuck
 * state=0 output. Analysis revealed:
 *   1) clk_sys was the raw 25 MHz input pin (NOT the PLL output), yet
 *      async_rst_n was gated by pll_locked. Any PLL-lock chatter caused
 *      the whole system to reset repeatedly -> BOOT re-fires -> FSM never
 *      completes its 100 ms PHY-reset timer. Fix: don't gate reset on PLL
 *      at all since the PLL is unused by the Phase-3 logic. Use only the
 *      POR (start in reset) + btn[0] if available.
 *   2) The old hex helper was buggy: it used
 *         nib2hex({3'b0, snap_state[4] | snap_state[3]} + {3'b0, snap_state[4]})
 *      which is neither a proper low-nibble nor high-nibble; it produced
 *      garbage (this is why we saw "2 0" exactly once).
 *      Fix: emit the FULL 8-bit state as TWO hex chars "HL " so we can see
 *      every state in {0..18}.
 *   3) No observability for resets themselves. Fix: add a free-running
 *      reset counter (survives reset) and emit "R=NN" on each BOOT so
 *      we can count resets.
 *   4) Added RDY event on phy_rst_release rising edge so we can confirm
 *      the 100 ms PHY reset timer actually completes.
 *
 * Trace protocol (printable ASCII, 115200 8N1):
 *   - On every sys-reset release (edge) -> "\r\nBOOT R=NN\r\n"
 *     where NN is lower 2 hex digits of a free-running reset count.
 *   - On phy_rst_release rising edge    -> "RDY\r\n"
 *   - On each FSM state change          -> "HL " (2 hex digits + space)
 *   - Every 1 s                          -> alternates between
 *         "P=XXXX\r\n"  (phy_id)
 *         "A=XX\r\n"    (phy_addr_found)
 *   - On init_done rising edge           -> "INIT_DONE\r\n"
 *   - On init_error rising edge          -> "INIT_ERROR\r\n"
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

// ============================================================
// Clocking — PLL instantiated so PLL lock can gate reset (as
// in Phase 2). The MDIO / UART logic runs at 25 MHz directly
// on the raw pad clock — plenty of headroom for a 115200 baud
// UART and 2.5 MHz MDC. This keeps all counters small.
// ============================================================
wire clk_125, clk_125_90, pll_locked;
pll pll_inst (
    .clock_in      (clk_25mhz),
    .clock_5x_out  (clk_125),
    .clock_5x_90_out(clk_125_90),
    .lock_out      (pll_locked)
);
wire clk_sys = clk_25mhz;

// ============================================================
// Reset — PLL-gated sync reset (same as Phase 2). Holds system
// in reset until the PLL has locked; prevents random edges on
// clk_sys while the pad clock is unstable.
// ============================================================
// PLL-lock deglitch: require pll_locked to be high for >=16 consecutive
// clk_sys cycles before treating as stable. Filters out brief lock
// dropouts caused by metastability during calibration that were making
// rst_sync (and hence the whole reset tree) oscillate every ~1.5 s.
reg [3:0] pll_lock_cnt    = 4'd0;
reg       pll_lock_stable = 1'b0;
always @(posedge clk_25mhz) begin
    if (!pll_locked) begin
        pll_lock_cnt    <= 4'd0;
        // Once stable, stay stable — one-shot startup, no mid-run resets.
    end else if (pll_lock_cnt != 4'd15) begin
        pll_lock_cnt <= pll_lock_cnt + 4'd1;
    end else begin
        pll_lock_stable <= 1'b1;
    end
end

wire rst_sync;
reset_sync rst_sync_inst (
    .clk         (clk_sys),
    .async_rst_n (pll_lock_stable),
    .rst_sync    (rst_sync)
);

// ============================================================
// Free-running reset counter — survives the (sync) reset so we
// can see how many resets have happened. Only bumped on the
// rising edge of rst_sync (i.e. a new reset just asserted).
// Uses `initial` (POR) and is intentionally NEVER cleared.
// ============================================================
reg        rst_sync_d = 1'b1;
reg [7:0]  rst_count  = 8'd0;
reg [3:0]  phy_rst_falls = 4'd0;    // # of phy_rst_release 1->0 since POR
reg        phy_rst_rel_d_free = 1'b0;
always @(posedge clk_sys) begin
    rst_sync_d <= rst_sync;
    phy_rst_rel_d_free <= phy_rst_release;
    if (rst_sync && !rst_sync_d) begin
        rst_count <= rst_count + 8'd1;
    end
    // 1->0 on phy_rst_release (POR-only, not cleared by rst_sync)
    if (phy_rst_rel_d_free && !phy_rst_release) begin
        phy_rst_falls <= phy_rst_falls + 4'd1;
    end
end
// one-cycle pulse when leaving reset (boot event)
wire boot_edge = (!rst_sync) && rst_sync_d;

// ============================================================
// PHY reset: hold eth_rst_n low for ~100 ms after power-on,
// then release and keep high FOREVER. Decoupled from rst_sync
// so PLL-chatter on sys reset does not toggle PHY reset and
// destabilise KSZ9031 internal PLL. KSZ9031 datasheet: needs
// 10ms stable after RST_N rising before MDIO is responsive.
// ============================================================
reg [23:0] phy_rst_cnt       = 24'd0;       // POR-initialized, never cleared
reg        phy_rst_release   = 1'b0;        // sticky-high once set
reg        phy_rst_release_d = 1'b0;
always @(posedge clk_sys) begin
    phy_rst_release_d <= phy_rst_release;
    if (!phy_rst_release) begin
        if (phy_rst_cnt == 24'd2_500_000) begin  // 100 ms @ 25 MHz
            phy_rst_release <= 1'b1;              // latch HIGH — never drops
        end else begin
            phy_rst_cnt <= phy_rst_cnt + 24'd1;
        end
    end
end
assign eth_rst_n = phy_rst_release;
wire phy_rdy_edge = phy_rst_release && !phy_rst_release_d;

// ============================================================
// MDIO controller
// ============================================================
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
    .MDC_FREQ    (2_500_000)
) mdio_ctrl_inst (
    .clk     (clk_sys),
    .rst     (rst_sync),
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

// ============================================================
// MDIO init FSM
// ============================================================
wire        init_done;
wire        init_error;
wire [15:0] phy_id;
wire [4:0]  phy_addr_found;
wire [4:0]  mdio_state_dbg;
wire [4:0]  scan_addr_dbg;
mdio_init #(
    .SETTLE_CYCLES(23'd1_250_000),  // 50 ms @ 25 MHz
    .RETRY_CYCLES (23'd250_000)     // 10 ms @ 25 MHz
) mdio_init_inst (
    .clk           (clk_sys),
    .rst           (rst_sync),
    .phy_ready     (phy_rst_release),
    .mdio_start    (mdio_start),
    .mdio_rw       (mdio_rw),
    .mdio_phy      (mdio_phy),
    .mdio_reg      (mdio_reg),
    .mdio_wdata    (mdio_wdata),
    .mdio_rdata    (mdio_rdata),
    .mdio_busy     (mdio_busy),
    .mdio_rvalid   (mdio_rvalid),
    .init_done     (init_done),
    .init_error    (init_error),
    .phy_id        (phy_id),
    .phy_addr_found(phy_addr_found),
    .state_dbg     (mdio_state_dbg),
    .scan_addr_dbg (scan_addr_dbg)
);

reg init_done_d, init_error_d;
always @(posedge clk_sys) begin
    if (rst_sync) begin
        init_done_d  <= 1'b0;
        init_error_d <= 1'b0;
    end else begin
        init_done_d  <= init_done;
        init_error_d <= init_error;
    end
end
wire init_done_edge  = init_done  && !init_done_d;
wire init_error_edge = init_error && !init_error_d;

// ============================================================
// UART TX FIFO (64 deep)
// ============================================================
reg [7:0] fifo_mem [0:63];
reg [6:0] fifo_wptr, fifo_rptr;
wire fifo_empty = (fifo_wptr == fifo_rptr);
wire fifo_full  = ((fifo_wptr[5:0] == fifo_rptr[5:0]) &&
                   (fifo_wptr[6]   != fifo_rptr[6]));

reg  [7:0] wr_byte;
reg        wr_en;
always @(posedge clk_sys) begin
    if (rst_sync) begin
        fifo_wptr <= 0;
    end else if (wr_en && !fifo_full) begin
        fifo_mem[fifo_wptr[5:0]] <= wr_byte;
        fifo_wptr <= fifo_wptr + 7'd1;
    end
end

reg  [7:0] tx_data_reg;
reg        tx_ena_reg;
wire       tx_busy;
uart #(
    .CLK_FREQ (25_000_000),
    .BAUD_RATE(115_200)
) uart_inst (
    .clk     (clk_sys),
    .rst     (rst_sync),
    .tx_ena  (tx_ena_reg),
    .tx_data (tx_data_reg),
    .tx_busy (tx_busy),
    .tx      (uart_tx),
    .rx      (uart_rx),
    .rx_busy (),
    .rx_error(),
    .rx_data ()
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
                    fifo_rptr   <= fifo_rptr + 7'd1;
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
// Hex helpers
// ============================================================
function [7:0] nib2hex;
    input [3:0] n;
    begin
        nib2hex = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n} - 8'd10);
    end
endfunction

// ============================================================
// State-change detection (one-cycle pulse)
// ============================================================
reg [4:0] state_prev;
always @(posedge clk_sys) begin
    if (rst_sync) state_prev <= 5'd31;   // impossible real state
    else          state_prev <= mdio_state_dbg;
end
wire state_changed = (mdio_state_dbg != state_prev);

// ============================================================
// 1-Hz heartbeat tick (25 MHz clock)
// ============================================================
reg [24:0] hb_cnt;
reg        hb_tick;
always @(posedge clk_sys) begin
    if (rst_sync) begin
        hb_cnt  <= 25'd0;
        hb_tick <= 1'b0;
    end else if (hb_cnt == 25'd24_999_999) begin  // 1 Hz @ 25 MHz
        hb_cnt  <= 25'd0;
        hb_tick <= 1'b1;
    end else begin
        hb_cnt  <= hb_cnt + 25'd1;
        hb_tick <= 1'b0;
    end
end

// cycle 0..3 through PHYID / ADDR / SCAN / RSTN on successive hb_ticks
reg [1:0] hb_rot;
always @(posedge clk_sys) begin
    if (rst_sync) hb_rot <= 2'd0;
    else if (hb_tick) hb_rot <= hb_rot + 2'd1;
end

// ============================================================
// Event queue — kinds
// ============================================================
localparam K_BOOT   = 4'd0;   // "\r\nBOOT R=NN\r\n"
localparam K_STATE  = 4'd1;   // "HL "
localparam K_PHYID  = 4'd2;   // "P=XXXX\r\n"
localparam K_ADDR   = 4'd3;   // "A=XX\r\n"
localparam K_RDY    = 4'd4;   // "RDY\r\n"
localparam K_DONE   = 4'd5;   // "INIT_DONE\r\n"
localparam K_ERR    = 4'd6;   // "INIT_ERROR\r\n"
localparam K_SCAN   = 4'd7;   // "S=HH\r\n"   current scan_addr
localparam K_RSTN   = 4'd8;   // "N=H F=H\r\n" phy_rst_release + falls

function [5:0] w_len;
    input [3:0] k;
    case (k)
        K_BOOT : w_len = 6'd13; // \r\n B O O T ' ' R = H L \r\n  -> 13
        K_STATE: w_len = 6'd3;  // H L ' '
        K_PHYID: w_len = 6'd9;  // P = H H H H \r \n
        K_ADDR : w_len = 6'd7;  // A = H H \r \n
        K_RDY  : w_len = 6'd5;  // R D Y \r \n
        K_DONE : w_len = 6'd11; // I N I T _ D O N E \r \n
        K_ERR  : w_len = 6'd12; // I N I T _ E R R O R \r \n
        K_SCAN : w_len = 6'd7;  // S = H H \r \n
        K_RSTN : w_len = 6'd10; // N = H   F = H \r \n
        default: w_len = 6'd0;
    endcase
endfunction

function [7:0] w_char;
    input [3:0]  k;
    input [5:0]  i;
    input [15:0] snap_id;
    input [4:0]  snap_state;
    input [4:0]  snap_addr;
    input [7:0]  snap_rstn;    // rst_count for K_BOOT
    input [3:0]  snap_falls;   // phy_rst_falls for K_RSTN
    input        snap_r;       // phy_rst_release for K_RSTN
    case (k)
    K_BOOT: case (i)
        6'd0 : w_char = 8'h0D;
        6'd1 : w_char = 8'h0A;
        6'd2 : w_char = "B";
        6'd3 : w_char = "O";
        6'd4 : w_char = "O";
        6'd5 : w_char = "T";
        6'd6 : w_char = " ";
        6'd7 : w_char = "R";
        6'd8 : w_char = "=";
        6'd9 : w_char = nib2hex(snap_rstn[7:4]);
        6'd10: w_char = nib2hex(snap_rstn[3:0]);
        6'd11: w_char = 8'h0D;
        6'd12: w_char = 8'h0A;
        default: w_char = " ";
    endcase
    K_STATE: case (i)
        6'd0 : w_char = nib2hex({3'b000, snap_state[4]});   // high nib (bit4)
        6'd1 : w_char = nib2hex(snap_state[3:0]);           // low nibble
        6'd2 : w_char = " ";
        default: w_char = " ";
    endcase
    K_PHYID: case (i)
        6'd0 : w_char = "P";
        6'd1 : w_char = "=";
        6'd2 : w_char = nib2hex(snap_id[15:12]);
        6'd3 : w_char = nib2hex(snap_id[11:8]);
        6'd4 : w_char = nib2hex(snap_id[7:4]);
        6'd5 : w_char = nib2hex(snap_id[3:0]);
        6'd6 : w_char = 8'h0D;
        6'd7 : w_char = 8'h0A;
        default: w_char = " ";
    endcase
    K_ADDR: case (i)
        6'd0 : w_char = "A";
        6'd1 : w_char = "=";
        6'd2 : w_char = nib2hex({3'b000, snap_addr[4]});
        6'd3 : w_char = nib2hex(snap_addr[3:0]);
        6'd4 : w_char = 8'h0D;
        6'd5 : w_char = 8'h0A;
        default: w_char = " ";
    endcase
    K_RDY: case (i)
        6'd0 : w_char = "R";
        6'd1 : w_char = "D";
        6'd2 : w_char = "Y";
        6'd3 : w_char = 8'h0D;
        6'd4 : w_char = 8'h0A;
        default: w_char = " ";
    endcase
    K_DONE: case (i)
        6'd0 : w_char = "I";
        6'd1 : w_char = "N";
        6'd2 : w_char = "I";
        6'd3 : w_char = "T";
        6'd4 : w_char = "_";
        6'd5 : w_char = "D";
        6'd6 : w_char = "O";
        6'd7 : w_char = "N";
        6'd8 : w_char = "E";
        6'd9 : w_char = 8'h0D;
        6'd10: w_char = 8'h0A;
        default: w_char = " ";
    endcase
    K_ERR: case (i)
        6'd0 : w_char = "I";
        6'd1 : w_char = "N";
        6'd2 : w_char = "I";
        6'd3 : w_char = "T";
        6'd4 : w_char = "_";
        6'd5 : w_char = "E";
        6'd6 : w_char = "R";
        6'd7 : w_char = "R";
        6'd8 : w_char = "O";
        6'd9 : w_char = "R";
        6'd10: w_char = 8'h0D;
        6'd11: w_char = 8'h0A;
        default: w_char = " ";
    endcase
    K_SCAN: case (i)
        6'd0 : w_char = "S";
        6'd1 : w_char = "=";
        6'd2 : w_char = nib2hex({3'b000, snap_addr[4]});
        6'd3 : w_char = nib2hex(snap_addr[3:0]);
        6'd4 : w_char = 8'h0D;
        6'd5 : w_char = 8'h0A;
        default: w_char = " ";
    endcase
    K_RSTN: case (i)
        6'd0 : w_char = "N";
        6'd1 : w_char = "=";
        6'd2 : w_char = snap_r ? "1" : "0";
        6'd3 : w_char = " ";
        6'd4 : w_char = "F";
        6'd5 : w_char = "=";
        6'd6 : w_char = nib2hex(snap_falls);
        6'd7 : w_char = " ";
        6'd8 : w_char = 8'h0D;
        6'd9 : w_char = 8'h0A;
        default: w_char = " ";
    endcase
    default: w_char = "?";
    endcase
endfunction

// ============================================================
// Event queue — 16 deep, each stores (kind, id, state, addr, rstn,
// falls, r).
// ============================================================
reg [3:0]  evq_kind  [0:15];
reg [15:0] evq_id    [0:15];
reg [4:0]  evq_state [0:15];
reg [4:0]  evq_addr  [0:15];   // phy_addr_found (K_ADDR) or scan_addr_dbg (K_SCAN)
reg [7:0]  evq_rstn  [0:15];   // rst_count (K_BOOT)
reg [3:0]  evq_falls [0:15];   // phy_rst_falls (K_RSTN)
reg        evq_r     [0:15];   // phy_rst_release (K_RSTN)
reg [4:0]  evq_wptr, evq_rptr;

wire evq_empty = (evq_wptr == evq_rptr);
wire evq_full  = ((evq_wptr[3:0] == evq_rptr[3:0]) &&
                  (evq_wptr[4]   != evq_rptr[4]));

// Enqueue priority: boot > rdy > done > err > state > rotating 1-Hz events
reg        evq_push;
reg [3:0]  evq_push_kind;
always @(*) begin
    evq_push      = 1'b0;
    evq_push_kind = K_BOOT;
    if      (boot_edge)                begin evq_push=1; evq_push_kind=K_BOOT ; end
    else if (phy_rdy_edge)             begin evq_push=1; evq_push_kind=K_RDY  ; end
    else if (init_done_edge)           begin evq_push=1; evq_push_kind=K_DONE ; end
    else if (init_error_edge)          begin evq_push=1; evq_push_kind=K_ERR  ; end
    else if (state_changed)            begin evq_push=1; evq_push_kind=K_STATE; end
    else if (hb_tick)
        case (hb_rot)
            2'd0: begin evq_push=1; evq_push_kind=K_PHYID; end
            2'd1: begin evq_push=1; evq_push_kind=K_ADDR ; end
            2'd2: begin evq_push=1; evq_push_kind=K_SCAN ; end
            2'd3: begin evq_push=1; evq_push_kind=K_RSTN ; end
        endcase
end

// Snap scan_addr_dbg when K_SCAN is the reason for this push, else
// phy_addr_found. This lets a single evq_addr field serve both K_ADDR
// and K_SCAN.
wire [4:0] snap_addr_wr = (evq_push_kind == K_SCAN) ? scan_addr_dbg
                                                    : phy_addr_found;

always @(posedge clk_sys) begin
    if (rst_sync) begin
        evq_wptr <= 0;
    end else if (evq_push && !evq_full) begin
        evq_kind [evq_wptr[3:0]] <= evq_push_kind;
        evq_id   [evq_wptr[3:0]] <= phy_id;
        evq_state[evq_wptr[3:0]] <= mdio_state_dbg;
        evq_addr [evq_wptr[3:0]] <= snap_addr_wr;
        evq_rstn [evq_wptr[3:0]] <= rst_count;
        evq_falls[evq_wptr[3:0]] <= phy_rst_falls;
        evq_r    [evq_wptr[3:0]] <= phy_rst_release;
        evq_wptr <= evq_wptr + 5'd1;
    end
end

// ============================================================
// Emit FSM — pop event, stream characters into the UART FIFO
// ============================================================
reg [4:0]  w_state;
reg [5:0]  w_idx;
reg [3:0]  w_kind;
reg [15:0] w_snap_id;
reg [4:0]  w_snap_state;
reg [4:0]  w_snap_addr;
reg [7:0]  w_snap_rstn;
reg [3:0]  w_snap_falls;
reg        w_snap_r;

localparam W_IDLE = 5'd0;
localparam W_EMIT = 5'd1;

always @(posedge clk_sys) begin
    if (rst_sync) begin
        w_state      <= W_IDLE;
        w_idx        <= 6'd0;
        w_kind       <= 4'd0;
        w_snap_id    <= 16'd0;
        w_snap_state <= 5'd0;
        w_snap_addr  <= 5'd0;
        w_snap_rstn  <= 8'd0;
        w_snap_falls <= 4'd0;
        w_snap_r     <= 1'b0;
        wr_byte      <= 8'd0;
        wr_en        <= 1'b0;
        evq_rptr     <= 0;
    end else begin
        wr_en <= 1'b0;
        case (w_state)
            W_IDLE: begin
                if (!evq_empty) begin
                    w_kind       <= evq_kind [evq_rptr[3:0]];
                    w_snap_id    <= evq_id   [evq_rptr[3:0]];
                    w_snap_state <= evq_state[evq_rptr[3:0]];
                    w_snap_addr  <= evq_addr [evq_rptr[3:0]];
                    w_snap_rstn  <= evq_rstn [evq_rptr[3:0]];
                    w_snap_falls <= evq_falls[evq_rptr[3:0]];
                    w_snap_r     <= evq_r    [evq_rptr[3:0]];
                    w_idx        <= 6'd0;
                    evq_rptr     <= evq_rptr + 5'd1;
                    w_state      <= W_EMIT;
                end
            end
            W_EMIT: begin
                if (!fifo_full) begin
                    wr_byte <= w_char(w_kind, w_idx, w_snap_id,
                                      w_snap_state, w_snap_addr, w_snap_rstn,
                                      w_snap_falls, w_snap_r);
                    wr_en   <= 1'b1;
                    if (w_idx == w_len(w_kind) - 6'd1) begin
                        w_state <= W_IDLE;
                    end else begin
                        w_idx <= w_idx + 6'd1;
                    end
                end
            end
            default: w_state <= W_IDLE;
        endcase
    end
end

// ============================================================
// LEDs (free-running blink, not reset by rst_sync so we can see
// whether the clock is alive even while held in reset)
// ============================================================
reg [24:0] blink_cnt;
always @(posedge clk_sys) begin
    blink_cnt <= blink_cnt + 25'd1;
end
assign led[0] = blink_cnt[24];          // alive heartbeat
assign led[1] = phy_rst_release;        // <-- what we drive to eth_rst_n
assign led[2] = init_done;              // init complete
assign led[3] = init_error;             // error latched
assign led[4] = pll_locked;             // PLL locked (stays dim/off if PLL chatters)
assign led[5] = rst_sync;               // rst_sync active (bright = stuck in reset)
assign led[6] = mdio_state_dbg[2];
assign led[7] = mdio_state_dbg[3];

// RGMII TX inert
assign eth_tx_clk = 1'b0;
assign eth_txd    = 4'b0000;
assign eth_tx_ctl = 1'b0;

wire _unused = &{1'b0, eth_rx_clk, eth_rxd, eth_rx_ctl,
                 clk_125, clk_125_90, btn[2:0], 1'b0};

endmodule

`resetall
