// tb_eth100.v — end-to-end test of eth100_top at the RGMII pins (100 Mb/s)
//
// A KSZ9031 stand-in drives RXC/RXD/RX_CTL, answers MDIO at PHYAD 3 and captures TX.
// Checks: MDIO init sequence (64-edge frames, PHYAD 3, reg9/reg4/reg0 values), ARP reply,
// ICMP echo reply (type 0, valid IP + ICMP checksums, same payload), UDP echo on port 1234,
// TX phase (TXD/TX_CTL identical at the rising and the falling TXC edge, >= 8 ns from a
// data change), and the UART status line.
`timescale 1ns/1ps
`default_nettype none

module tb_eth100;

reg clk25 = 1'b0;
always #20 clk25 = ~clk25;

wire [7:0] led;
wire uart_tx, uart_tx_alt;
wire eth_tx_clk, eth_tx_ctl, eth_rst_n, eth_mdc;
wire [3:0] eth_txd;
reg  eth_rx_clk = 1'b0;
reg  [3:0] eth_rxd = 4'h0;
reg  eth_rx_ctl = 1'b0;
wire eth_mdio;
pullup (eth_mdio);

eth100_top #(
    .PHY_RST_BIT(10),
    .MDIO_SETTLE(24'd200),
    .MDIO_POLL(24'd20000),
    .STATUS_TICKS(26'd400_000)
) dut (
    .clk_25mhz(clk25), .led(led), .uart_tx(uart_tx), .uart_tx_alt(uart_tx_alt), .uart_rx(1'b1),
    .eth_tx_clk(eth_tx_clk), .eth_txd(eth_txd), .eth_tx_ctl(eth_tx_ctl),
    .eth_rx_clk(eth_rx_clk), .eth_rxd(eth_rxd), .eth_rx_ctl(eth_rx_ctl),
    .eth_rst_n(eth_rst_n), .eth_mdc(eth_mdc), .eth_mdio(eth_mdio)
);

integer errors = 0;
task fail(input [8*80-1:0] msg); begin errors = errors + 1; $display("FAIL: %0s", msg); end endtask

// ------------------------------------------------------------------ RXC (PHY clock, unrelated phase)
initial begin #7; forever #20 eth_rx_clk = ~eth_rx_clk; end

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
        5'd31: phy_reg = 16'h0328;
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

// ------------------------------------------------------------------ RX driver (PHY -> FPGA)
task send_frame;
    integer k; reg [31:0] c; reg [7:0] b;
    begin
        while (flen < 60) begin fr[flen] = 8'h00; flen = flen + 1; end
        c = 32'hFFFFFFFF;
        for (k = 0; k < flen; k = k + 1) c = crc_byte(c, fr[k]);
        c = ~c;
        @(negedge eth_rx_clk);
        eth_rx_ctl = 1'b1;
        for (k = 0; k < 15; k = k + 1) begin eth_rxd = 4'h5; @(negedge eth_rx_clk); end
        eth_rxd = 4'hD; @(negedge eth_rx_clk);
        for (k = 0; k < flen + 4; k = k + 1) begin
            b = (k < flen) ? fr[k] : c[8*(k-flen) +: 8];
            eth_rxd = b[3:0]; @(negedge eth_rx_clk);
            eth_rxd = b[7:4]; @(negedge eth_rx_clk);
        end
        eth_rx_ctl = 1'b0; eth_rxd = 4'hD;  // in-band status: link up, 100M, FD
        repeat (24) @(negedge eth_rx_clk);
    end
endtask

task put_hdr(input [15:0] etype);
    begin
        {fr[0],fr[1],fr[2],fr[3],fr[4],fr[5]}   = 48'h10e2d5000000;
        {fr[6],fr[7],fr[8],fr[9],fr[10],fr[11]} = 48'h02000000000e;
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
        {fr[26],fr[27],fr[28],fr[29]} = 32'hc0a80a0e;
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

// ------------------------------------------------------------------ TX monitor (FPGA -> PHY)
reg [7:0] tx [0:1599];
integer   tx_n = 0;     // bytes after SFD
integer   nib = 0;
reg [3:0] lo_nib;
reg       in_tx = 1'b0;
reg       got_sfd = 1'b0;
integer   tx_frames_seen = 0;
reg [3:0] rise_d; reg rise_c;
time      last_data_change = 0;
time      min_margin = 1000;
integer   arp_ok = 0, icmp_ok = 0, udp_ok = 0;

always @(eth_txd or eth_tx_ctl) last_data_change = $time;

always @(posedge eth_tx_clk) begin
    if ($time - last_data_change < min_margin && eth_tx_ctl) min_margin = $time - last_data_change;
    rise_d = eth_txd; rise_c = eth_tx_ctl;
    if (eth_tx_ctl) begin
        if (!in_tx) begin in_tx = 1'b1; got_sfd = 1'b0; nib = 0; tx_n = 0; end
        if (!got_sfd) begin
            if (eth_txd == 4'hD) got_sfd = 1'b1;
            else if (eth_txd != 4'h5) fail("TX preamble nibble");
        end else begin
            if (nib == 0) begin lo_nib = eth_txd; nib = 1; end
            else begin tx[tx_n] = {eth_txd, lo_nib}; tx_n = tx_n + 1; nib = 0; end
        end
    end else if (in_tx) begin
        in_tx = 1'b0;
        check_tx;
    end
end
always @(negedge eth_tx_clk) begin
    if ($time - last_data_change < min_margin && eth_tx_ctl) min_margin = $time - last_data_change;
    if (eth_tx_ctl !== rise_c || (rise_c && eth_txd !== rise_d)) fail("TX value differs between TXC edges");
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
            if ({tx[0],tx[1],tx[2],tx[3],tx[4],tx[5]} != 48'h02000000000e) fail("ICMP dest MAC");
            icmp_ok = icmp_ok + 1;
            $display("%t TX ICMP echo reply ok (IP len %0d)", $time, {tx[16],tx[17]});
        end else if (et == 16'h0800 && tx[23] == 8'd17) begin
            if ({tx[34],tx[35]} != 16'd1234 || {tx[36],tx[37]} != 16'd5555) fail("UDP ports");
            for (k = 0; k < 14; k = k + 1) if (tx[42+k] != udp_msg[8*(13-k) +: 8]) begin
                fail("UDP payload");
                $display("  byte %0d: got %02h want %02h", k, tx[42+k], udp_msg[8*(13-k) +: 8]);
            end
            udp_ok = udp_ok + 1;
            $display("%t TX UDP echo ok", $time);
        end else begin
            $display("%t TX other frame type %04h (%0d bytes)", $time, et, tx_n);
        end
    end
endtask

// ------------------------------------------------------------------ UART decoder (115200)
localparam real BIT_NS = 1.0e9 / 115200.0;
reg [7:0] uline [0:199];
integer   ulen = 0;
integer   lines = 0;
reg [8*120-1:0] last_line;
always begin : uart_rx
    integer k; reg [7:0] ch;
    @(negedge uart_tx);
    #(BIT_NS * 1.5);
    for (k = 0; k < 8; k = k + 1) begin ch[k] = uart_tx; #(BIT_NS); end
    if (ch == 8'h0A) begin
        last_line = 0;
        for (k = 0; k < ulen && k < 120; k = k + 1) last_line = {last_line[8*119-1:0], uline[k]};
        lines = lines + 1;
        $display("%t UART: %0s", $time, last_line);
        ulen = 0;
    end else if (ch != 8'h0D) begin
        uline[ulen] = ch; ulen = ulen + 1;
    end
end

// ------------------------------------------------------------------ sequence
initial begin
    $timeformat(-6, 1, " us", 10);
    wait (eth_rst_n === 1'b1);
    $display("%t PHY out of reset", $time);
    wait (wr_r0 !== 16'hXXXX);
    if (wr_r9 !== 16'h0000) fail("reg9 != 0x0000");
    if (wr_r4 !== 16'h0101) fail("reg4 != 0x0101");
    if (wr_r0 !== 16'h1200) fail("reg0 != 0x1200");
    #2000;
    build_arp_request; send_frame;
    #30000;
    build_icmp_request; send_frame;
    #40000;
    icmp_len = 1000; build_icmp_request; send_frame;
    #250000;
    build_udp; send_frame;
    #40000;
    wait (lines >= 1);
    #1000;
    $display("SUMMARY: mdio_writes=%0d mdio_reads=%0d arp=%0d icmp=%0d udp=%0d tx_frames=%0d min_txc_margin=%0d ns uart_lines=%0d led=%b",
             writes, reads_ok, arp_ok, icmp_ok, udp_ok, tx_frames_seen, min_margin, lines, led);
    if (arp_ok != 1) fail("ARP reply count");
    if (icmp_ok != 2) fail("ICMP reply count");
    if (udp_ok != 1) fail("UDP echo count");
    if (min_margin < 8) fail("TXC edge closer than 8 ns to a data change");
    if (led[1] !== 1'b1) fail("LED1 (MDIO ID) off");
    if (errors == 0) $display("PASS"); else $display("FAILED with %0d errors", errors);
    $finish;
end

initial begin #30_000_000; $display("TIMEOUT"); $finish; end

endmodule
