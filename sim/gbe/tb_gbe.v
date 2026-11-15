// tb_gbe.v — end-to-end test of gbe_top at the RGMII pins (1000 Mb/s)
//
// A KSZ9031 stand-in drives RXC (125 MHz) / RXD / RX_CTL as DDR, answers MDIO at PHYAD 3 and
// captures TX (DDR on TXC). Checks: MDIO 1000FD advert (reg9 0x0200, reg4 0x0001, reg0 0x1200),
// ARP reply, ICMP echo 64/1000/1472 B (valid checksums, same payload), two back-to-back pings,
// UDP echo on 1234, UDP burst on 1235 (1 + BURST_N identical valid datagrams at line rate),
// TX setup/hold of TXD/TX_CTL around TXC, UART status line.
// RX_LATE = 0: RXD changes 1.2 ns before the RXC edge (alignment A); 1: 1 ns after it (B).
`timescale 1ns/1ps
`default_nettype none

module tb_gbe;
parameter RX_LATE = 0;
localparam BURST_N = 5;

reg clk25 = 1'b0;
always #20 clk25 = ~clk25;

wire [7:0] led;
wire uart_tx, uart_tx_alt;
wire eth_tx_clk, eth_tx_ctl, eth_rst_n, eth_mdc;
wire [3:0] eth_txd;
reg  eth_rx_clk = 1'b0;
reg  [3:0] eth_rxd = 4'hD;
reg  eth_rx_ctl = 1'b0;
wire eth_mdio;
pullup (eth_mdio);

gbe_top #(
    .PHY_RST_BIT(10),
    .MDIO_SETTLE(24'd200),
    .MDIO_POLL(24'd20000),
    .STATUS_TICKS(26'd60_000),
    .BURST_N(BURST_N),
    .UART_BAUD(2_500_000),
    .ARP_RETRY(20_000)                 // 0.8 ms instead of 2 s
) dut (
    .clk_25mhz(clk25), .led(led), .uart_tx(uart_tx), .uart_tx_alt(uart_tx_alt), .uart_rx(1'b1),
    .eth_tx_clk(eth_tx_clk), .eth_txd(eth_txd), .eth_tx_ctl(eth_tx_ctl),
    .eth_rx_clk(eth_rx_clk), .eth_rxd(eth_rxd), .eth_rx_ctl(eth_rx_ctl),
    .eth_rst_n(eth_rst_n), .eth_mdc(eth_mdc), .eth_mdio(eth_mdio)
);

integer errors = 0;
task fail(input [8*80-1:0] msg); begin errors = errors + 1; $display("%t FAIL: %0s", $time, msg); end endtask

// iverilog does not run `always @*` at time 0. In eth_axis_rx (8-bit, OFFSET = 0) the block that
// sets shift_axis_input_tready = 1 reads only signals that never change before the first frame here
// (MAC RX on clk), so it stays X and the X spreads through tready. Give it its constant value once.
initial begin
    #1 force dut.core_inst.eth_axis_rx_inst.shift_axis_input_tready = 1'b1;
    #1 release dut.core_inst.eth_axis_rx_inst.shift_axis_input_tready;
end

// ------------------------------------------------------------------ RXC (PHY clock, 125 MHz, own phase)
initial begin #3.3; forever #4 eth_rx_clk = ~eth_rx_clk; end

// HELPERS
// ------------------------------------------------------------------ MDIO PHY model
reg        mdio_drv = 1'b0, mdio_val = 1'b1;
assign eth_mdio = mdio_drv ? mdio_val : 1'bz;
reg [63:0] mshift = 64'd0;
integer    mbits = 0;          // bits since a valid start
reg        in_frame = 1'b0;
reg [1:0]  m_op;
reg [4:0]  m_phy, m_reg;
reg [15:0] m_rd, m_wr;
integer    ones = 0;
integer    writes = 0;
reg [15:0] wr_r9 = 16'hXXXX, wr_r4 = 16'hXXXX, wr_r0 = 16'hXXXX;
integer    reads_ok = 0;

function [15:0] phy_reg(input [4:0] r);
    case (r)
        5'd1:  phy_reg = 16'h796D;
        5'd2:  phy_reg = 16'h0022;
        5'd3:  phy_reg = 16'h1622;
        5'd31: phy_reg = 16'h0348;
        default: phy_reg = 16'h0000;
    endcase
endfunction

always @(posedge eth_mdc) begin
    if (!in_frame) begin
        // preamble: >= 32 ones, then start 01
        if (eth_mdio === 1'b1) ones = ones + 1;
        else if (ones >= 32) begin in_frame = 1'b1; mbits = 1; end   // the '0' of start
        else ones = 0;
    end else begin
        mbits = mbits + 1;
        mshift = {mshift[62:0], eth_mdio === 1'b1};
        if (mbits == 2 && mshift[0] !== 1'b1) begin fail("MDIO start bits"); in_frame = 1'b0; ones = 0; end
        if (mbits == 4)  m_op  = mshift[1:0];
        if (mbits == 9)  m_phy = mshift[4:0];
        if (mbits == 14) begin
            m_reg = mshift[4:0];
            if (m_phy != 5'd3) fail("MDIO PHYAD != 3");
            if (m_op == 2'b10) m_rd = phy_reg(m_reg);
        end
        if (mbits == 32) begin
            if (m_op == 2'b01) begin
                m_wr = mshift[15:0];
                writes = writes + 1;
                if (m_reg == 5'd9) wr_r9 = m_wr;
                if (m_reg == 5'd4) wr_r4 = m_wr;
                if (m_reg == 5'd0) wr_r0 = m_wr;
                $display("%t MDIO write reg %0d = %04h", $time, m_reg, m_wr);
            end else begin
                reads_ok = reads_ok + 1;
            end
            in_frame = 1'b0; ones = 0;
        end
    end
end
// read: PHY drives TA low (2nd TA bit) and D15..D0, changing 50 ns after each rising MDC edge
always @(posedge eth_mdc) begin
    #50;
    if (in_frame && m_op == 2'b10 && mbits >= 15 && mbits <= 31) begin
        mdio_drv = 1'b1;
        mdio_val = (mbits == 15) ? 1'b0 : m_rd[31 - mbits];
    end else begin
        mdio_drv = 1'b0;
    end
end

// ------------------------------------------------------------------ CRC / checksums
function [31:0] crc_byte(input [31:0] c, input [7:0] d);
    integer k; reg [31:0] x;
    begin
        x = c ^ {24'd0, d};
        for (k = 0; k < 8; k = k + 1) x = x[0] ? (x >> 1) ^ 32'hEDB88320 : (x >> 1);
        crc_byte = x;
    end
endfunction

reg [7:0] fr [0:1599];   // frame under construction (dst MAC .. payload, no FCS)
integer   flen;

function [15:0] csum(input integer start, input integer len);
    integer k; reg [31:0] s;
    begin
        s = 0;
        for (k = 0; k < len; k = k + 2)
            s = s + {fr[start+k], (k+1 < len) ? fr[start+k+1] : 8'h00};
        s = (s & 32'hFFFF) + (s >> 16);
        s = (s & 32'hFFFF) + (s >> 16);
        csum = ~s[15:0];
    end
endfunction

integer   arp_req = 0, udp21_ok = 0, udp21_last = -1, k21, rxd_before = -1;
reg [47:0] src_mac = 48'h02000000000e;
reg [31:0] src_ip  = 32'hc0a80a0e;
task put_hdr(input [15:0] etype);
    begin
        {fr[0],fr[1],fr[2],fr[3],fr[4],fr[5]}   = 48'h10e2d5000000;
        {fr[6],fr[7],fr[8],fr[9],fr[10],fr[11]} = src_mac;
        {fr[12],fr[13]} = etype;
    end
endtask

task build_arp_request;
    begin
        put_hdr(16'h0806);
        {fr[0],fr[1],fr[2],fr[3],fr[4],fr[5]} = 48'hFFFFFFFFFFFF;
        {fr[14],fr[15],fr[16],fr[17],fr[18],fr[19],fr[20],fr[21]} = 64'h0001_0800_06_04_0001;
        {fr[22],fr[23],fr[24],fr[25],fr[26],fr[27]} = 48'h02000000000e;
        {fr[28],fr[29],fr[30],fr[31]} = 32'hc0a80a0e;
        {fr[32],fr[33],fr[34],fr[35],fr[36],fr[37]} = 48'h0;
        {fr[38],fr[39],fr[40],fr[41]} = 32'hc0a80a96;
        flen = 42;
    end
endtask

task build_ip(input [7:0] proto, input integer plen);  // plen = IP payload bytes (already in fr[34..])
    reg [15:0] c;
    begin
        put_hdr(16'h0800);
        fr[14] = 8'h45; fr[15] = 8'h00;
        {fr[16],fr[17]} = 20 + plen;
        {fr[18],fr[19]} = 16'h1234; {fr[20],fr[21]} = 16'h4000;
        fr[22] = 8'd64; fr[23] = proto; {fr[24],fr[25]} = 16'h0000;
        {fr[26],fr[27],fr[28],fr[29]} = src_ip;
        {fr[30],fr[31],fr[32],fr[33]} = 32'hc0a80a96;
        c = csum(14, 20); {fr[24],fr[25]} = c;
        flen = 34 + plen;
    end
endtask

integer icmp_len = 64;
reg [7:0] icmp_sent [0:1599];
task build_icmp_request;
    integer k; reg [15:0] c;
    begin
        fr[34] = 8'h08; fr[35] = 8'h00; fr[36] = 8'h00; fr[37] = 8'h00;
        {fr[38],fr[39]} = 16'h0042; {fr[40],fr[41]} = 16'h0007;
        for (k = 8; k < icmp_len; k = k + 1) fr[34+k] = k * 7 + 3;
        c = csum(34, icmp_len); {fr[36],fr[37]} = c;
        for (k = 0; k < icmp_len; k = k + 1) icmp_sent[k] = fr[34+k];
        build_ip(8'd1, icmp_len);
    end
endtask

reg [8*14-1:0] udp_msg = "hello GateMate";
task build_udp;
    integer k;
    begin
        {fr[34],fr[35]} = 16'd5555; {fr[36],fr[37]} = 16'd1234;
        {fr[38],fr[39]} = 16'd8 + 16'd14; {fr[40],fr[41]} = 16'h0000;
        for (k = 0; k < 14; k = k + 1) fr[42+k] = udp_msg[8*(13-k) +: 8];
        build_ip(8'd17, 22);
    end
endtask

task build_arp_reply;
    begin
        put_hdr(16'h0806);
        {fr[14],fr[15],fr[16],fr[17],fr[18],fr[19],fr[20],fr[21]} = 64'h0001_0800_06_04_0002;
        {fr[22],fr[23],fr[24],fr[25],fr[26],fr[27]} = src_mac;
        {fr[28],fr[29],fr[30],fr[31]} = src_ip;
        {fr[32],fr[33],fr[34],fr[35],fr[36],fr[37]} = 48'h10e2d5000000;
        {fr[38],fr[39],fr[40],fr[41]} = 32'hc0a80a96;
        flen = 42;
    end
endtask

task build_udp_big(input [15:0] sport, input [15:0] seq);
    integer k;
    begin
        {fr[34],fr[35]} = sport; {fr[36],fr[37]} = 16'd1234;
        {fr[38],fr[39]} = 16'd8 + 16'd1472; {fr[40],fr[41]} = 16'h0000;
        {fr[42],fr[43]} = seq;
        for (k = 2; k < 1472; k = k + 1) fr[42+k] = 8'hA5;
        build_ip(8'd17, 1480);
    end
endtask

// reply to every ARP request the FPGA has sent for host .21 since the last call
integer arp_replied = 0;
task answer_arp;
    begin
        if (arp_req > arp_replied) begin
            arp_replied = arp_req;
            build_arp_reply; send_frame_ifg(12);
            $display("%t RX ARP reply from .21 (request #%0d)", $time, arp_req);
        end
    end
endtask

// burst trigger: 1472-byte datagram to port 1235
task build_udp_burst;
    integer k;
    begin
        {fr[34],fr[35]} = 16'd5556; {fr[36],fr[37]} = 16'd1235;
        {fr[38],fr[39]} = 16'd8 + 16'd1472; {fr[40],fr[41]} = 16'h0000;
        for (k = 0; k < 1472; k = k + 1) fr[42+k] = k[7:0] ^ 8'h5A;
        build_ip(8'd17, 1480);
    end
endtask

// ------------------------------------------------------------------ UART decoder (115200)
localparam real BIT_NS = 1.0e9 / 2500000.0;
reg [7:0] uline [0:199];
integer   ulen = 0;
integer   lines = 0;
reg [8*130-1:0] last_line;
always begin : uart_rx
    integer k; reg [7:0] ch;
    @(negedge uart_tx);
    #(BIT_NS * 1.5);
    for (k = 0; k < 8; k = k + 1) begin ch[k] = uart_tx; #(BIT_NS); end
    if (ch == 8'h0A) begin
        last_line = 0;
        for (k = 0; k < ulen && k < 130; k = k + 1) last_line = {last_line[8*129-1:0], uline[k]};
        lines = lines + 1;
        $display("%t UART: %0s", $time, last_line);
        ulen = 0;
    end else if (ch != 8'h0D) begin
        uline[ulen] = ch; ulen = ulen + 1;
    end
end

// ------------------------------------------------------------------ RX driver (PHY -> FPGA, DDR)
task drive_nib(input [3:0] d, input lo);   // lo: nibble meant for the rising edge
    begin
        if (!RX_LATE) begin
            if (lo) @(negedge eth_rx_clk); else @(posedge eth_rx_clk);
            #2.8;
        end else begin
            if (lo) @(posedge eth_rx_clk); else @(negedge eth_rx_clk);
            #1.0;
        end
        eth_rxd = d;
    end
endtask

task send_frame_ifg(input integer ifg);
    integer k; reg [31:0] c; reg [7:0] b;
    begin
        while (flen < 60) begin fr[flen] = 8'h00; flen = flen + 1; end
        c = 32'hFFFFFFFF;
        for (k = 0; k < flen; k = k + 1) c = crc_byte(c, fr[k]);
        c = ~c;
        for (k = 0; k < 8 + flen + 4; k = k + 1) begin
            b = (k < 7) ? 8'h55 : (k == 7) ? 8'hD5 : (k < 8 + flen) ? fr[k-8] : c[8*(k-8-flen) +: 8];
            drive_nib(b[3:0], 1'b1); if (k == 0) eth_rx_ctl = 1'b1;
            drive_nib(b[7:4], 1'b0);
        end
        drive_nib(4'hD, 1'b1); eth_rx_ctl = 1'b0;   // in-band status: link up, 1000M, FD
        drive_nib(4'hD, 1'b0);
        for (k = 1; k < ifg; k = k + 1) begin drive_nib(4'hD, 1'b1); drive_nib(4'hD, 1'b0); end
    end
endtask
task send_frame; send_frame_ifg(12); endtask

// ------------------------------------------------------------------ TX monitor (FPGA -> PHY)
reg [7:0] tx [0:1599];
reg [7:0] burst0 [0:1599];
integer   tx_n = 0;     // bytes after SFD
integer   pre_n = 0;
reg [3:0] lo_nib;
reg       lo_ctl;
reg       in_tx = 1'b0;
reg       got_sfd = 1'b0;
integer   tx_frames_seen = 0;
time      last_data_change = 0, last_txc_edge = 0;
time      min_setup = 1000, min_hold = 1000;
integer   arp_ok = 0, icmp_ok = 0, udp_ok = 0, burst_ok = 0, burst_n0 = 0;
time      frame_start = 0, burst_t0 = 0, burst_t1 = 0, burst_min_period = 1_000_000;
time      prev_burst_start = 0;
integer   idle_cycles = 0, min_ifg = 1000;

always @(eth_txd or eth_tx_ctl) begin
    if (in_tx && $time - last_txc_edge < min_hold) min_hold = $time - last_txc_edge;
    last_data_change = $time;
end

always @(posedge eth_tx_clk) begin
    last_txc_edge = $time;
    if (in_tx && $time - last_data_change < min_setup) min_setup = $time - last_data_change;
    lo_nib = eth_txd; lo_ctl = eth_tx_ctl;
end
always @(negedge eth_tx_clk) begin : tx_byte
    reg [7:0] byte_v;
    last_txc_edge = $time;
    if (in_tx && $time - last_data_change < min_setup) min_setup = $time - last_data_change;
    if (lo_ctl !== eth_tx_ctl) fail("TX_CTL differs between TXC edges (TX_ER?)");
    byte_v = {eth_txd, lo_nib};
    if (lo_ctl) begin
        if (!in_tx) begin
            in_tx = 1'b1; got_sfd = 1'b0; tx_n = 0; pre_n = 0; frame_start = $time;
            if (tx_frames_seen > 0 && idle_cycles < min_ifg) min_ifg = idle_cycles;
        end
        if (!got_sfd) begin
            if (byte_v == 8'hD5) begin
                got_sfd = 1'b1;
                if (pre_n != 7) fail("TX preamble length != 7");
            end else if (byte_v != 8'h55) fail("TX preamble byte");
            else pre_n = pre_n + 1;
        end else begin
            tx[tx_n] = byte_v; tx_n = tx_n + 1;
        end
    end else begin
        if (in_tx) begin in_tx = 1'b0; idle_cycles = 0; check_tx; end
        idle_cycles = idle_cycles + 1;
    end
end

task check_tx;
    integer k; reg [31:0] c; reg [15:0] et, s;
    begin
        tx_frames_seen = tx_frames_seen + 1;
        c = 32'hFFFFFFFF;
        for (k = 0; k < tx_n - 4; k = k + 1) c = crc_byte(c, tx[k]);
        c = ~c;
        if (c != {tx[tx_n-1], tx[tx_n-2], tx[tx_n-3], tx[tx_n-4]}) fail("TX FCS");
        for (k = 0; k < tx_n; k = k + 1) fr[k] = tx[k];
        et = {tx[12], tx[13]};
        if (et == 16'h0806 && {tx[20],tx[21]} == 16'h0002 &&
            {tx[28],tx[29],tx[30],tx[31]} == 32'hc0a80a96 &&
            {tx[22],tx[23],tx[24],tx[25],tx[26],tx[27]} == 48'h10e2d5000000) begin
            arp_ok = arp_ok + 1;
            $display("%t TX ARP reply ok (%0d bytes)", $time, tx_n);
        end else if (et == 16'h0800 && tx[23] == 8'd1) begin
            s = csum(14, 20);
            if (s != 16'h0000) fail("TX IP header checksum");
            if (tx[34] != 8'h00) fail("ICMP type != 0");
            s = csum(34, {tx[16],tx[17]} - 20);
            if (s != 16'h0000) fail("ICMP checksum");
            for (k = 4; k < icmp_len; k = k + 1) if (tx[34+k] != icmp_sent[k]) fail("ICMP payload");
            if ({tx[30],tx[31],tx[32],tx[33]} != 32'hc0a80a0e) fail("ICMP dest IP");
            icmp_ok = icmp_ok + 1;
            $display("%t TX ICMP echo reply ok (IP len %0d)", $time, {tx[16],tx[17]});
        end else if (et == 16'h0800 && tx[23] == 8'd17 && {tx[34],tx[35]} == 16'd1235) begin
            s = csum(14, 20);
            if (s != 16'h0000) fail("burst IP header checksum");
            if ({tx[36],tx[37]} != 16'd5556 || {tx[16],tx[17]} != 16'd1500) fail("burst ports/length");
            if (burst_ok == 0) begin
                for (k = 0; k < tx_n; k = k + 1) burst0[k] = tx[k];
                burst_n0 = tx_n;
                for (k = 0; k < 1472; k = k + 1) if (tx[42+k] != (k[7:0] ^ 8'h5A)) fail("burst payload");
                burst_t0 = frame_start;
            end else begin
                if (tx_n != burst_n0) fail("burst copy length");
                for (k = 0; k < tx_n; k = k + 1) if (tx[k] != burst0[k]) fail("burst copy differs");
                if (frame_start - prev_burst_start < burst_min_period) burst_min_period = frame_start - prev_burst_start;
            end
            prev_burst_start = frame_start;
            burst_t1 = $time;
            burst_ok = burst_ok + 1;
        end else if (et == 16'h0806 && {tx[20],tx[21]} == 16'h0001) begin
            arp_req = arp_req + 1;
            $display("%t TX ARP request for %0d.%0d.%0d.%0d", $time, tx[38], tx[39], tx[40], tx[41]);
        end else if (et == 16'h0800 && tx[23] == 8'd17 && {tx[36],tx[37]} == 16'd5557) begin
            if ({tx[30],tx[31],tx[32],tx[33]} != 32'hc0a80a15 || {tx[0],tx[1],tx[2],tx[3],tx[4],tx[5]} != 48'h020000000015)
                fail("echo to host .21: wrong IP/MAC");
            udp21_ok = udp21_ok + 1;
            udp21_last = {tx[42], tx[43]};
        end else if (et == 16'h0800 && tx[23] == 8'd17) begin
            if ({tx[34],tx[35]} != 16'd1234 || {tx[36],tx[37]} != 16'd5555) fail("UDP ports");
            for (k = 0; k < 14; k = k + 1) if (tx[42+k] != udp_msg[8*(13-k) +: 8]) fail("UDP payload");
            udp_ok = udp_ok + 1;
            $display("%t TX UDP echo ok", $time);
        end else begin
            $display("%t TX other frame type %04h (%0d bytes)", $time, et, tx_n);
        end
    end
endtask

// ------------------------------------------------------------------ sequence
initial begin
    $timeformat(-6, 2, " us", 10);
    wait (eth_rst_n === 1'b1);
    $display("%t PHY out of reset (RX_LATE=%0d)", $time, RX_LATE);
    wait (wr_r0 !== 16'hXXXX);
    if (wr_r9 !== 16'h0200) fail("reg9 != 0x0200");
    if (wr_r4 !== 16'h0001) fail("reg4 != 0x0001");
    if (wr_r0 !== 16'h1200) fail("reg0 != 0x1200");
    #2000;
    if (RX_LATE) begin
        // the frame that shows the other nibble pairing only switches `sel`; it is lost (as in gbe_phy.py)
        build_arp_request; send_frame;
        #30000;
    end
    build_arp_request; send_frame;
    #30000;
    icmp_len = 64;   build_icmp_request; send_frame;
    #40000;
    icmp_len = 1000; build_icmp_request; send_frame;
    #250000;
    icmp_len = 1480; build_icmp_request; send_frame;            // ping -s 1472
    #350000;
    icmp_len = 64;   build_icmp_request; send_frame_ifg(12);    // two pings back to back
                     build_icmp_request; send_frame_ifg(12);
    #80000;
    build_udp; send_frame;
    #40000;
    build_udp_burst; send_frame;
    #500000;
    // UDP flood from a host the FPGA has no ARP entry for (192.168.10.21): the first echo waits for
    // ARP; the RX path must keep flowing so the ARP reply that arrives during the flood is seen.
    rxd_before = dut.phy_inst.rx_drops;        // the flood itself overruns the 4 KiB RX buffer
    src_mac = 48'h020000000015; src_ip = 32'hc0a80a15;
    for (k21 = 0; k21 < 24; k21 = k21 + 1) begin
        build_udp_big(16'd5557, k21[15:0]); send_frame_ifg(12);
        answer_arp;                                 // in the middle of the flood (may be dropped)
    end
    if (arp_req == 0) fail("no ARP request for host .21");
    #400000;
    // the ARP module retries every ARP_RETRY cycles; answer each request (a quiet line now)
    repeat (3) begin #900000; answer_arp; end
    for (k21 = 100; k21 < 103; k21 = k21 + 1) begin build_udp_big(16'd5557, k21[15:0]); send_frame; #200000; end
    src_mac = 48'h02000000000e; src_ip = 32'hc0a80a0e;
    icmp_len = 64; build_icmp_request; send_frame;               // the first host still gets answers
    #100000;
    wait (lines >= 1);
    #1000;
    $display("SUMMARY: mdio_writes=%0d mdio_reads=%0d arp=%0d icmp=%0d udp=%0d burst=%0d tx_frames=%0d",
             writes, reads_ok, arp_ok, icmp_ok, udp_ok, burst_ok, tx_frames_seen);
    $display("SUMMARY: txd setup=%0.2f ns hold=%0.2f ns, min IFG=%0d byte times, burst frame period=%0t (line rate %0.1f Mb/s payload)",
             min_setup, min_hold, min_ifg, burst_min_period,
             (burst_ok > 1) ? 1472.0 * 8.0 * 1000.0 / burst_min_period : 0.0);
    $display("SUMMARY: arp_req=%0d udp21=%0d (last seq %0d)", arp_req, udp21_ok, udp21_last);
    $display("SUMMARY: rx_flips=%0d rx_drops=%0d tx_drops=%0d tx_bursts=%0d sel=%0d led=%b",
             dut.phy_inst.rx_flips, dut.phy_inst.rx_drops, dut.phy_inst.tx_drops, dut.phy_inst.tx_bursts,
             dut.phy_inst.sel, led);
    if (arp_ok != 1) fail("ARP reply count");
    if (icmp_ok != 6) fail("ICMP reply count");
    if (udp21_ok < 4) fail("echoes to host .21 after ARP-under-load < 4");
    if (udp21_last != 102) fail("last echo to host .21 is not seq 102");
    if (udp_ok != 1) fail("UDP echo count");
    if (burst_ok != BURST_N + 1) fail("burst copy count");
    if (dut.phy_inst.tx_bursts != 1) fail("tx_bursts != 1");
    if (dut.phy_inst.rx_flips != RX_LATE) fail("rx_flips != expected pairing changes");
    if (rxd_before != 0) fail("rx_drops before the flood != 0");
    if (burst_min_period > (8 + 1514 + 4 + 16) * 8) fail("burst slower than line rate");
    if (min_ifg < 12) fail("IFG < 12 bytes");
    if (min_setup < 1.5 || min_hold < 1.5) fail("TXD/TX_CTL setup or hold < 1.5 ns around TXC");
    if (led[1] !== 1'b1) fail("LED1 (MDIO ID) off");
    if (led[3] !== 1'b1) fail("LED3 (1000FD) off");
    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
end

initial begin #40_000_000; $display("TIMEOUT"); $finish; end

endmodule
