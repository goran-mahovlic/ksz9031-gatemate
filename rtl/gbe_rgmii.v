/*
 * gbe_rgmii.v — 1000 Mb/s RGMII for GateMate (ULX5M-GS + KSZ9031) behind a slow GMII byte stream
 *
 * Verilog port of gateware/gbe_phy.py from litex-eth-ulx5m-gs-1g (TASK-5032, pinged on this board
 * at 1000FD, tag gbe-1000m-ping-ok-20260925). The idea is unchanged:
 *
 *   The 125 MHz domains (gtx = TX, rxc = RX) hold only the IO registers, a byte-wide RX aligner,
 *   a 4-byte shift register per direction and a 36-bit BRAM port whose address moves at most once
 *   every 4 cycles. GateMate routing costs 1.5..3.6 ns per hop, so at 8 ns only one LUT level
 *   (<= 4 inputs) fits between two flip-flops; every gtx/rxc register below has a next-state
 *   function of at most 4 inputs, a plain shift, or a carry-chain increment. No synchronous resets
 *   there: they start from the configuration values.
 *
 *   The clock crossing is store-and-forward per WHOLE frame through a BRAM in each direction, so the
 *   slow side (clk, here the 25 MHz MAC + stack) only ever sees complete frames and may be much
 *   slower than the line.
 *
 * Difference to gbe_phy.py: the slow side is a GMII byte stream (one byte per clk, preamble + SFD +
 * frame + FCS, as produced/consumed by Forencich eth_mac_1g with MII_SELECT = 0) instead of a
 * LiteEth stream. TX frames cannot be back-pressured: a frame that does not fit is dropped whole
 * (tx_drops). RX frames are replayed to the MAC as 2 preamble bytes + the stored bytes (the store
 * starts at the SFD).
 *
 * Burst replay (throughput test): a TX frame that is IPv4/UDP with source port BURST_PORT (the
 * echo of a datagram sent to BURST_PORT) is put on the wire 1 + BURST_N times back to back, with
 * the normal 12-byte gap, by rewinding the gtx read pointer to the start of the frame. The frame is
 * bit-identical each time (same IP ID, checksums and FCS), so every copy is a valid datagram. The
 * writer only gets back the space of a frame once it is fully sent (released pointer `rel`, which
 * walks one word per 4 cycles so its gray code crosses safely).
 *
 * Word layout of both frame buffers: data[31:0] (lane 0 = first byte), nv[33:32] = valid bytes in
 * the last word (0 = 4), burst[34] (TX only), last[35].
 *
 * RX alignment: the KSZ9031 RXC edge lands ~1.2 ns after the data edge and reaches the IDDR through
 * the non-clock pin IO_EB_A7 + CC_BUFG, so which half of the RXC period samples which nibble depends
 * on that insertion delay. Both pairings are decoded in parallel and the one that shows the SFD first
 * is locked for the frame (A: rising edge = low nibble, B: rising edge = high nibble of the previous
 * byte). Frames with RX_ER, without SFD or not fitting the buffer are dropped (rx_drops).
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gbe_rgmii #(
    parameter        AW         = 10,          // 1024 words = 4 KiB per direction
    parameter [15:0] BURST_PORT = 16'd1235,
    parameter [15:0] BURST_N    = 16'd50000    // extra copies of a burst frame
) (
    input  wire        clk,          // slow side (GMII byte stream)
    input  wire        gtx,          // 125 MHz, PLL CLK0
    input  wire        txc_in,       // 125 MHz, PLL CLK90 through CC_BUFG (goes straight to the pad)
    input  wire        rxc,          // RXC after CC_BUFG

    input  wire [7:0]  s_txd,
    input  wire        s_tx_en,
    output reg  [7:0]  s_rxd,
    output reg         s_rx_dv,

    output wire        rgmii_txc,
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,

    output reg  [15:0] tx_drops,     // clk: TX frames that did not fit
    output reg  [15:0] tx_bursts,    // gtx: bursts completed (read quasi-statically)
    output reg  [15:0] rx_frames,    // clk: frames replayed to the MAC
    output reg  [7:0]  rx_drops,     // rxc
    output reg  [7:0]  rx_flips      // rxc: RX nibble pairing changes
);

localparam [AW-1:0] MAXW = 384;      // words reserved per frame (8 B preamble + 1522 B = 383 words)
localparam          GAP  = 3;        // idle words after a TX frame: 12 B inter-frame gap

function [AW-1:0] gray;
    input [AW-1:0] b;
    gray = b ^ (b >> 1);
endfunction

function [AW-1:0] gray2bin;
    input [AW-1:0] g;
    integer k;
    begin
        gray2bin[AW-1] = g[AW-1];
        for (k = AW - 2; k >= 0; k = k - 1)
            gray2bin[k] = gray2bin[k+1] ^ g[k];
    end
endfunction

initial begin
    tx_drops = 0; tx_bursts = 0; rx_frames = 0; rx_drops = 0; rx_flips = 0;
    s_rxd = 0; s_rx_dv = 0;
end

// =================================================================================== TX
reg [35:0] txmem [0:(1<<AW)-1];

// ---------------------------------------------------------------- clk: frame writer
reg [7:0]    b1 = 0;
reg          e1 = 1'b0;
always @(posedge clk) begin
    b1 <= s_txd;
    e1 <= s_tx_en;
end
wire blast = e1 & ~s_tx_en;               // b1 is the last byte of the frame

reg [AW-1:0] t_wa = 0, t_wc = 0, t_wc_g = 0;
(* keep *) reg [AW-1:0] t_rel_s0 = 0;
(* keep *) reg [AW-1:0] t_rel_s1 = 0;
reg [AW-1:0] t_rel_g = 0;                  // gtx
wire [AW-1:0] t_rel  = gray2bin(t_rel_s1);
wire [AW-1:0] t_free = t_rel - t_wa - 1'b1;
always @(posedge clk) begin
    t_rel_s0 <= t_rel_g;
    t_rel_s1 <= t_rel_s0;
end

reg          in_fr = 1'b0, acc = 1'b0, ovf = 1'b0, rb = 1'b0;
reg [1:0]    lane = 0;
reg [10:0]   idx = 0;
reg [8:0]    wcnt = 0;
reg [31:0]   word = 0;
reg          brst = 1'b0;
reg          wpend = 1'b0;
reg [35:0]   wdat = 0;
reg [31:0]   wnext;
always @* begin
    wnext = word;
    case (lane)
        2'd0: wnext[7:0]   = b1;
        2'd1: wnext[15:8]  = b1;
        2'd2: wnext[23:16] = b1;
        2'd3: wnext[31:24] = b1;
    endcase
end
wire acc_now = in_fr ? (acc & ~ovf) : (t_free >= MAXW);

// IPv4 / IHL 5 / UDP / source port BURST_PORT, offsets in the GMII stream (8 B preamble + SFD first)
reg bmatch;
always @* begin
    case (idx)
        11'd20:  bmatch = (b1 == 8'h08);
        11'd21:  bmatch = (b1 == 8'h00);
        11'd22:  bmatch = (b1 == 8'h45);
        11'd31:  bmatch = (b1 == 8'h11);
        11'd42:  bmatch = (b1 == BURST_PORT[15:8]);
        11'd43:  bmatch = (b1 == BURST_PORT[7:0]);
        default: bmatch = 1'b1;
    endcase
end

always @(posedge clk) begin
    wpend <= 1'b0;
    rb    <= 1'b0;
    if (wpend) begin
        txmem[t_wa] <= wdat;
        t_wa <= t_wa + 1'b1;
        if (wdat[35]) t_wc <= t_wa + 1'b1;
    end
    if (rb) t_wa <= t_wc;                  // overflow rollback (the frame never fits; not expected)
    if (!e1) begin
        in_fr <= 1'b0;
        lane  <= 2'd0;
        idx   <= 11'd0;
    end else begin
        in_fr <= ~blast;
        if (!in_fr) begin
            acc  <= acc_now;
            ovf  <= 1'b0;
            wcnt <= 9'd0;
            brst <= 1'b1;
            if (!acc_now) tx_drops <= tx_drops + 1'b1;
        end else begin
            brst <= brst & bmatch;
        end
        word <= wnext;
        lane <= lane + 1'b1;
        idx  <= idx + 1'b1;
        if ((lane == 2'd3 || blast) && acc_now) begin
            if (wcnt == MAXW - 1) begin
                ovf <= 1'b1;
            end else begin
                wpend <= 1'b1;
                wcnt  <= wcnt + 1'b1;
                wdat  <= {blast, brst, lane + 2'd1, wnext};
            end
        end
        if (blast && (ovf || (wcnt == MAXW - 1 && acc_now))) rb <= 1'b1;
    end
    t_wc_g <= gray(t_wc);
end

// ---------------------------------------------------------------- gtx: word reader + byte serializer
//  4-phase ring, p[k] = phase k:
//  p0: go = inside a frame, or (gap over and a committed word available); rel/fs and rep compares
//  p1: golast / gonl / gob (BRAM data for the new ra is valid)
//  p2: mask, idle_nx, inc, rewind decisions
//  p3: load sh/vb, fact, idle; ra/fs/rel/rep/bact update at the end of p3
(* keep *) reg [AW-1:0] wc_gs0 = 0;
(* keep *) reg [AW-1:0] wc_gs  = 0;
reg [3:0]    p = 4'b0001;
reg [AW-1:0] ra = 0, ra_g = 0, fs = 0, rel = 0;
reg [31:0]   sh = 0;
reg [3:0]    vb = 0;
reg          fact = 1'b0;
reg [GAP-1:0] idle = 0, idle_nx = 0;
reg          go = 1'b0, golast = 1'b0, gonl = 1'b0, gob = 1'b0, inc = 1'b0;
reg          rw = 1'b0, bend = 1'b0, af = 1'b0;
reg [3:0]    mask = 0;
reg [AW-1:0] x = 0, xr = 0;
reg [2:0]    orq = 0, orr = 0;
reg          avail = 1'b0, rne = 1'b0;
reg [15:0]   rep = 0;
reg [3:0]    zq = 0;
reg          rz = 1'b0, bact = 1'b0;
reg [35:0]   dat = 0;

wire       ld    = p[3];
// copies of p[3] for the 36 shift-register muxes (one flip-flop drove all of them: 5.6 ns of routing,
// gtx 97 MHz on seed 1). CC_DFF instances, since yosys opt_merge folds plain copies even with keep.
wire [4:0] ld_c;
genvar g;
generate
    for (g = 0; g < 5; g = g + 1) begin : g_ld
        CC_DFF #(.CLK_INV(1'b0), .EN_INV(1'b0), .SR_INV(1'b0), .SR_VAL(1'b0)) ld_dup (
            .D(p[2]), .CLK(gtx), .EN(1'b1), .SR(1'b0), .Q(ld_c[g]));
    end
endgenerate
wire [1:0] nv    = dat[33:32];
wire       wlst  = dat[35];
wire       wbrst = dat[34];

integer i;
always @(posedge gtx) begin
    dat    <= txmem[ra];
    wc_gs0 <= t_wc_g;
    wc_gs  <= wc_gs0;
    // self-correcting one-hot ring: any state converges to one hot bit within 4 cycles
    p      <= {p[2], p[1], p[0], ~(p[0] | p[1] | p[2])};
    // avail = (gray(ra) != committed gray pointer), 3 stages
    ra_g   <= gray(ra);
    x      <= ra_g ^ wc_gs;
    orq[0] <= |x[3:0];
    orq[1] <= |x[7:4];
    orq[2] <= |x[AW-1:8];
    avail  <= |orq;
    if (p[0]) begin
        go    <= fact | (~idle[0] & avail);
        xr    <= rel ^ fs;
        zq[0] <= rep[3:0]   == 4'd0;
        zq[1] <= rep[7:4]   == 4'd0;
        zq[2] <= rep[11:8]  == 4'd0;
        zq[3] <= rep[15:12] == 4'd0;
    end
    if (p[1]) begin
        golast <= go & wlst;
        gonl   <= go & ~wlst;
        gob    <= go & wlst & wbrst;
        orr[0] <= |xr[3:0];
        orr[1] <= |xr[7:4];
        orr[2] <= |xr[AW-1:8];
        rz     <= &zq;
    end
    if (p[2]) begin
        case (nv)
            2'd0: mask <= 4'b1111;
            2'd1: mask <= 4'b0001;
            2'd2: mask <= 4'b0011;
            2'd3: mask <= 4'b0111;
        endcase
        inc  <= go;
        for (i = 0; i < GAP; i = i + 1)
            idle_nx[i] <= golast | (~go & ((i + 1 < GAP) ? idle[(i + 1) % GAP] : 1'b0));
        rw   <= gob & (~bact | ~rz);
        bend <= gob & bact & rz;
        af   <= golast & ~(gob & (~bact | ~rz));
        rne  <= |orr;
    end
    if (ld) begin
        fact <= gonl;
        idle <= idle_nx;
        ra   <= rw ? fs : ra + {{(AW-1){1'b0}}, inc};
        if (af) fs <= ra + 1'b1;
        rel  <= rel + {{(AW-1){1'b0}}, rne};
        if (rw)   bact <= 1'b1;
        if (bend) bact <= 1'b0;
        if (rw)   rep  <= bact ? rep - 1'b1 : BURST_N - 1'b1;
        if (bend) tx_bursts <= tx_bursts + 1'b1;
    end
    t_rel_g <= gray(rel);
    for (i = 0; i < 32; i = i + 1)
        sh[i] <= ld_c[i / 8] ? (dat[i] & go) : ((i + 8 < 32) ? sh[(i + 8) % 32] : 1'b0);
    for (i = 0; i < 4; i = i + 1)
        vb[i] <= ld_c[4] ? (mask[i] & go) : ((i + 1 < 4) ? vb[(i + 1) % 4] : 1'b0);
end

wire       tx_en   = vb[0];
wire [7:0] tx_byte = sh[7:0];

// ---------------------------------------------------------------- TX IO
// CC_ODDR per pin. D0 (rising half) from a posedge register, D1 (falling half) from a NEGEDGE fabric
// register, so both IO flip-flops get a full-cycle path from the fabric.
reg       en_r = 1'b0;
reg [3:0] lo_r = 0, hi_r = 0;
always @(posedge gtx) begin
    en_r <= tx_en;
    lo_r <= tx_en ? tx_byte[3:0] : 4'd0;
    hi_r <= tx_en ? tx_byte[7:4] : 4'd0;
end

wire [4:0] o_d0 = {en_r, lo_r};
wire [4:0] o_d1 = {en_r, hi_r};
wire [4:0] o_d1n;
wire [4:0] o_q;
generate
    for (g = 0; g < 5; g = g + 1) begin : g_oddr
        CC_DFF #(.CLK_INV(1'b1), .EN_INV(1'b0), .SR_INV(1'b0), .SR_VAL(1'b0)) d1neg (
            .D(o_d1[g]), .CLK(gtx), .EN(1'b1), .SR(1'b0), .Q(o_d1n[g]));
        CC_ODDR #(.CLK_INV(1'b0)) oddr (
            .D0(o_d0[g]), .D1(o_d1n[g]), .CLK(gtx), .DDR(gtx), .Q(o_q[g]));
    end
endgenerate
assign rgmii_tx_ctl = o_q[4];          // TX_EN on rising, TX_EN ^ TX_ER (= TX_EN) on falling
assign rgmii_txd    = o_q[3:0];
assign rgmii_txc    = txc_in;

// =================================================================================== RX
// ---------------------------------------------------------------- RX IO
// CC_IDDR per pin. Q0 (rising) -> posedge reg; Q1 (falling) -> negedge reg -> posedge reg.
// Result: rs = rising sample of cycle c, fs = falling sample before it.
wire [4:0] i_pad = {rgmii_rx_ctl, rgmii_rxd};
wire [4:0] i_q0, i_q1, i_q1n;
reg  [4:0] rs = 0, fsm = 0;
generate
    for (g = 0; g < 5; g = g + 1) begin : g_iddr
        CC_IDDR #(.CLK_INV(1'b0)) iddr (.D(i_pad[g]), .CLK(rxc), .Q0(i_q0[g]), .Q1(i_q1[g]));
        CC_DFF #(.CLK_INV(1'b1), .EN_INV(1'b0), .SR_INV(1'b0), .SR_VAL(1'b0)) q1neg (
            .D(i_q1[g]), .CLK(rxc), .EN(1'b1), .SR(1'b0), .Q(i_q1n[g]));
    end
endgenerate
always @(posedge rxc) begin
    rs  <= i_q0;
    fsm <= i_q1n;
end
wire       rs_c = rs[4];
wire [3:0] rs_d = rs[3:0];
wire       fs_c = fsm[4];
wire [3:0] fs_d = fsm[3:0];

// ---------------------------------------------------------------- rxc: aligner
reg       sel = 1'b0;
reg       rs_cp = 1'b0;
reg [3:0] rs_dp = 0;
reg [7:0] cA = 0, cB = 0, cS = 0;
reg       dvA = 0, dvB = 0, dvS = 0, erS = 0;
always @(posedge rxc) begin
    rs_cp <= rs_c;
    rs_dp <= rs_d;
    cA    <= {fs_d, rs_dp};  dvA <= rs_cp;     // A: {fall (prev half), rise (prev cycle)}
    cB    <= {rs_d, fs_d};   dvB <= fs_c;      // B: {rise (this cycle), fall (prev half)}
    cS    <= sel ? {rs_d, fs_d} : {fs_d, rs_dp};
    dvS   <= sel ? fs_c : rs_cp;
    erS   <= sel ? (fs_c ^ rs_c) : (rs_cp ^ fs_c);
end

// stage 2: nibble compares (low == 5, high == D); stage 3: SFD
reg loA = 0, hiA = 0, dv2A = 0, sfdA = 0;
reg loB = 0, hiB = 0, dv2B = 0, sfdB = 0;
reg loS = 0, hiS = 0, dv2S = 0, sfdS = 0;
reg [7:0] cS2 = 0, cS3 = 0;
reg dvS2 = 0, dvS3 = 0, erS2 = 0, erS3 = 0;
always @(posedge rxc) begin
    loA <= cA[3:0] == 4'h5; hiA <= cA[7:4] == 4'hD; dv2A <= dvA; sfdA <= dv2A & loA & hiA;
    loB <= cB[3:0] == 4'h5; hiB <= cB[7:4] == 4'hD; dv2B <= dvB; sfdB <= dv2B & loB & hiB;
    loS <= cS[3:0] == 4'h5; hiS <= cS[7:4] == 4'hD; dv2S <= dvS; sfdS <= dv2S & loS & hiS;
    cS2 <= cS;  cS3 <= cS2;
    dvS2 <= dvS; dvS3 <= dvS2;
    erS2 <= erS; erS3 <= erS2;
end

// stage 4: frame state on the selected path + pairing choice from the A/B SFD detectors
reg       inf = 1'b0, ov = 1'b0, ofirst = 1'b0, oer = 1'b0, sel_d = 1'b0;
reg [7:0] ob = 0;
wire      take = inf ? dvS3 : sfdS;
always @(posedge rxc) begin
    inf    <= take;
    ov     <= take;
    ofirst <= ~inf & sfdS;
    oer    <= inf & erS3;
    if (~inf & sfdB & ~sfdA)      sel <= 1'b1;
    else if (~inf & sfdA & ~sfdB) sel <= 1'b0;
    ob     <= cS3 & {8{take}};
    sel_d  <= sel;
    if (sel != sel_d) rx_flips <= rx_flips + 1'b1;
end

// stage 5+: frame writer. sr/vv shift every cycle; ph counts from the SFD; a word is complete when
// ph == 0 and it is written at the next edge (we_r).
reg [31:0]   sr = 0;
reg [3:0]    vv = 0;
reg [1:0]    ph = 0;
reg          we_r = 1'b0, racc = 1'b0, bad = 1'b0, rovf = 1'b0, commit = 1'b0, commit_ok = 1'b0;
reg [AW-1:0] r_wa = 0, r_wc = 0, r_wc_g = 0;
reg [8:0]    r_wcnt = 0;
reg          space_sys = 1'b0;
(* keep *) reg space_s0 = 1'b0;
(* keep *) reg space_ok = 1'b0;
wire we_nx = (ph == 2'd3) & vv[1] & racc;
wire [3:0] we_l;
generate
    for (g = 0; g < 4; g = g + 1) begin : g_we
        // 4 copies of we_r (one per 9-bit write lane): yosys opt_merge folds plain copies even with keep
        CC_DFF #(.CLK_INV(1'b0), .EN_INV(1'b0), .SR_INV(1'b0), .SR_VAL(1'b0)) we_dup (
            .D(we_nx), .CLK(rxc), .EN(1'b1), .SR(1'b0), .Q(we_l[g]));
    end
endgenerate
wire       r_wlast = ~(vv[3] & ov);
reg  [1:0] r_wnv;
always @* begin
    case (vv[3:1])
        3'b111:  r_wnv = 2'd0;
        3'b000:  r_wnv = 2'd1;
        3'b001:  r_wnv = 2'd2;
        3'b011:  r_wnv = 2'd3;
        default: r_wnv = 2'd0;
    endcase
end
wire [35:0] r_wdat = {r_wlast, 1'b0, r_wnv, sr};

reg [35:0] rxmem [0:(1<<AW)-1];
always @(posedge rxc) begin
    space_s0 <= space_sys;
    space_ok <= space_s0;
    sr     <= {ob, sr[31:8]};
    vv     <= {ov, vv[3:1]};
    ph     <= ofirst ? 2'd1 : ph + 1'b1;
    we_r   <= we_nx;
    racc   <= ofirst ? space_ok : (racc & ~rovf);
    bad    <= ofirst ? 1'b0 : (bad | oer);
    rovf   <= r_wcnt[8] & r_wcnt[7];
    r_wcnt <= ofirst ? 9'd0 : r_wcnt + {8'd0, we_r};
    commit    <= we_r & ~(vv[3] & ov);
    commit_ok <= we_r & ~(vv[3] & ov) & ~bad;
    if (commit_ok) r_wc <= r_wa;                         // r_wa already points past the last word
    r_wa   <= ofirst ? r_wc : r_wa + {{(AW-1){1'b0}}, we_r};
    if ((commit & bad) | (ofirst & ~space_ok)) rx_drops <= rx_drops + 1'b1;
    r_wc_g <= gray(r_wc);
    if (we_l[0]) rxmem[r_wa][8:0]   <= r_wdat[8:0];
    if (we_l[1]) rxmem[r_wa][17:9]  <= r_wdat[17:9];
    if (we_l[2]) rxmem[r_wa][26:18] <= r_wdat[26:18];
    if (we_l[3]) rxmem[r_wa][35:27] <= r_wdat[35:27];
end

// ---------------------------------------------------------------- clk: frame reader -> GMII
(* keep *) reg [AW-1:0] r_wc_s0 = 0;
(* keep *) reg [AW-1:0] r_wc_s1 = 0;
wire [AW-1:0] r_wc_s = gray2bin(r_wc_s1);
reg  [AW-1:0] r_ra = 0;
reg           space_pre = 1'b0;
reg  [1:0]    st = 2'd0;             // 0 idle, 1 preamble, 2 emit, 3 gap
reg  [3:0]    cnt = 0;
reg  [1:0]    ln = 0;
reg  [35:0]   wd = 0, rdat = 0;
wire [1:0]    nbm1 = wd[35] ? (wd[33:32] - 2'd1) : 2'd3;
wire [AW-1:0] r_adr = (st == 2'd2) ? r_ra + 1'b1 : r_ra;
wire [AW-1:0] r_free = r_ra - r_wc_s - 1'b1;
always @(posedge clk) begin
    r_wc_s0   <= r_wc_g;
    r_wc_s1   <= r_wc_s0;
    rdat      <= rxmem[r_adr];
    // two samples in a row: r_wc_s jumps by a whole frame, so one sample may be a torn gray code
    space_pre <= r_free >= MAXW;
    space_sys <= (r_free >= MAXW) & space_pre;
    s_rx_dv   <= 1'b0;
    s_rxd     <= 8'h00;
    case (st)
        2'd0: begin
            cnt <= 4'd0;
            if (r_ra != r_wc_s) st <= 2'd1;
        end
        2'd1: begin                      // 2 preamble bytes (the stored frame starts with the SFD)
            s_rx_dv <= 1'b1;
            s_rxd   <= 8'h55;
            cnt     <= cnt + 1'b1;
            if (cnt == 4'd1) begin
                wd <= rdat;
                ln <= 2'd0;
                st <= 2'd2;
            end
        end
        2'd2: begin
            s_rx_dv <= 1'b1;
            case (ln)
                2'd0: s_rxd <= wd[7:0];
                2'd1: s_rxd <= wd[15:8];
                2'd2: s_rxd <= wd[23:16];
                2'd3: s_rxd <= wd[31:24];
            endcase
            ln <= ln + 1'b1;
            if (ln == nbm1) begin
                r_ra <= r_ra + 1'b1;
                ln   <= 2'd0;
                if (wd[35]) begin
                    st        <= 2'd3;
                    cnt       <= 4'd0;
                    rx_frames <= rx_frames + 1'b1;
                end else begin
                    wd <= rdat;              // mem[r_ra + 1], read during lanes 0..2
                end
            end
        end
        2'd3: begin                      // inter-frame gap towards the MAC
            cnt <= cnt + 1'b1;
            if (cnt == 4'd11) st <= 2'd0;
        end
    endcase
end

endmodule

`resetall
