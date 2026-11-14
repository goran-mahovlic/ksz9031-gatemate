/*
 * eth_core.v — MAC + ARP/IP/UDP stack + ICMP echo + UDP echo (Forencich verilog-ethernet)
 *
 * Responds to ARP, ICMP echo (ping) and echoes every UDP datagram sent to UDP_PORT back to
 * the sender. The stack runs on clk; the MAC TX runs on tx_clk and RX on rx_clk, both
 * behind the MAC wrapper's asynchronous FIFOs.
 *
 * MII_SELECT = 1 (100 Mb/s): the MAC moves one nibble per enabled clock on gmii_*[3:0].
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module eth_core #(
    parameter [47:0] LOCAL_MAC  = 48'h10_e2_d5_00_00_00,
    parameter [31:0] LOCAL_IP   = {8'd192, 8'd168, 8'd10, 8'd150},
    parameter [31:0] GATEWAY_IP = {8'd192, 8'd168, 8'd10, 8'd1},
    parameter [31:0] SUBNET     = {8'd255, 8'd255, 8'd255, 8'd0},
    parameter [15:0] UDP_PORT   = 16'd1234,
    parameter        MII_SELECT = 1
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        tx_clk,         // MAC TX + gmii_tx_* + tx_clk_enable
    input  wire        tx_rst,
    input  wire        rx_clk,
    input  wire        rx_rst,

    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,
    output wire [7:0]  gmii_txd,
    output wire        gmii_tx_en,
    output wire        gmii_tx_er,
    input  wire        tx_clk_enable,

    output reg  [15:0] rx_frames,
    output reg  [15:0] rx_bad,
    output reg  [15:0] tx_frames,
    output wire [15:0] icmp_count,
    output reg  [15:0] udp_count
);

// ------------------------------------------------------------------ MAC
wire [7:0] rx_axis_tdata;
wire       rx_axis_tvalid, rx_axis_tready, rx_axis_tlast, rx_axis_tuser;
wire [7:0] tx_axis_tdata;
wire       tx_axis_tvalid, tx_axis_tready, tx_axis_tlast, tx_axis_tuser;
wire       rx_err_bad_fcs, rx_err_bad_frame;

gm_eth_mac_1g_fifo #(
    .ENABLE_PADDING(1),
    .MIN_FRAME_LENGTH(64),
    .TX_FIFO_DEPTH(4096),
    .RX_FIFO_DEPTH(4096)
) mac_inst (
    .rx_clk(rx_clk),
    .rx_rst(rx_rst),
    .tx_clk(tx_clk),
    .tx_rst(tx_rst),
    .logic_clk(clk),
    .logic_rst(rst),
    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tkeep(1'b1),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser),
    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tkeep(),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),
    .gmii_rxd(gmii_rxd),
    .gmii_rx_dv(gmii_rx_dv),
    .gmii_rx_er(gmii_rx_er),
    .gmii_txd(gmii_txd),
    .gmii_tx_en(gmii_tx_en),
    .gmii_tx_er(gmii_tx_er),
    .rx_clk_enable(1'b1),
    .tx_clk_enable(tx_clk_enable),
    .rx_mii_select(MII_SELECT[0]),
    .tx_mii_select(MII_SELECT[0]),
    .tx_error_underflow(),
    .tx_fifo_overflow(),
    .tx_fifo_bad_frame(),
    .tx_fifo_good_frame(),
    .rx_error_bad_frame(rx_err_bad_frame),
    .rx_error_bad_fcs(rx_err_bad_fcs),
    .rx_fifo_overflow(),
    .rx_fifo_bad_frame(),
    .rx_fifo_good_frame(),
    .cfg_ifg(8'd12),
    .cfg_tx_enable(1'b1),
    .cfg_rx_enable(1'b1)
);

always @(posedge clk) begin
    if (rst) begin
        rx_frames <= 16'd0;
        rx_bad    <= 16'd0;
        tx_frames <= 16'd0;
    end else begin
        if (rx_axis_tvalid && rx_axis_tready && rx_axis_tlast && !rx_axis_tuser)
            rx_frames <= rx_frames + 16'd1;
        if (rx_err_bad_fcs || rx_err_bad_frame)
            rx_bad <= rx_bad + 16'd1;
        if (tx_axis_tvalid && tx_axis_tready && tx_axis_tlast)
            tx_frames <= tx_frames + 16'd1;
    end
end

// ------------------------------------------------------------------ Ethernet framing
wire        rx_eth_hdr_valid, rx_eth_hdr_ready;
wire [47:0] rx_eth_dest_mac, rx_eth_src_mac;
wire [15:0] rx_eth_type;
wire [7:0]  rx_eth_payload_axis_tdata;
wire        rx_eth_payload_axis_tvalid, rx_eth_payload_axis_tready;
wire        rx_eth_payload_axis_tlast, rx_eth_payload_axis_tuser;

wire        tx_eth_hdr_valid, tx_eth_hdr_ready;
wire [47:0] tx_eth_dest_mac, tx_eth_src_mac;
wire [15:0] tx_eth_type;
wire [7:0]  tx_eth_payload_axis_tdata;
wire        tx_eth_payload_axis_tvalid, tx_eth_payload_axis_tready;
wire        tx_eth_payload_axis_tlast, tx_eth_payload_axis_tuser;

eth_axis_rx eth_axis_rx_inst (
    .clk(clk), .rst(rst),
    .s_axis_tdata(rx_axis_tdata), .s_axis_tvalid(rx_axis_tvalid), .s_axis_tready(rx_axis_tready),
    .s_axis_tlast(rx_axis_tlast), .s_axis_tuser(rx_axis_tuser),
    .m_eth_hdr_valid(rx_eth_hdr_valid), .m_eth_hdr_ready(rx_eth_hdr_ready),
    .m_eth_dest_mac(rx_eth_dest_mac), .m_eth_src_mac(rx_eth_src_mac), .m_eth_type(rx_eth_type),
    .m_eth_payload_axis_tdata(rx_eth_payload_axis_tdata),
    .m_eth_payload_axis_tvalid(rx_eth_payload_axis_tvalid),
    .m_eth_payload_axis_tready(rx_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(rx_eth_payload_axis_tlast),
    .m_eth_payload_axis_tuser(rx_eth_payload_axis_tuser),
    .busy(), .error_header_early_termination()
);

eth_axis_tx eth_axis_tx_inst (
    .clk(clk), .rst(rst),
    .s_eth_hdr_valid(tx_eth_hdr_valid), .s_eth_hdr_ready(tx_eth_hdr_ready),
    .s_eth_dest_mac(tx_eth_dest_mac), .s_eth_src_mac(tx_eth_src_mac), .s_eth_type(tx_eth_type),
    .s_eth_payload_axis_tdata(tx_eth_payload_axis_tdata),
    .s_eth_payload_axis_tvalid(tx_eth_payload_axis_tvalid),
    .s_eth_payload_axis_tready(tx_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(tx_eth_payload_axis_tlast),
    .s_eth_payload_axis_tuser(tx_eth_payload_axis_tuser),
    .m_axis_tdata(tx_axis_tdata), .m_axis_tvalid(tx_axis_tvalid), .m_axis_tready(tx_axis_tready),
    .m_axis_tlast(tx_axis_tlast), .m_axis_tuser(tx_axis_tuser),
    .busy()
);

// ------------------------------------------------------------------ IP / UDP
wire        rx_ip_hdr_valid, rx_ip_hdr_ready;
wire [7:0]  rx_ip_protocol;
wire [31:0] rx_ip_source_ip;
wire [7:0]  rx_ip_payload_axis_tdata;
wire        rx_ip_payload_axis_tvalid, rx_ip_payload_axis_tready;
wire        rx_ip_payload_axis_tlast, rx_ip_payload_axis_tuser;

wire        tx_ip_hdr_valid, tx_ip_hdr_ready;
wire [15:0] tx_ip_length;
wire [7:0]  tx_ip_ttl, tx_ip_protocol;
wire [31:0] tx_ip_dest_ip;
wire [7:0]  tx_ip_payload_axis_tdata;
wire        tx_ip_payload_axis_tvalid, tx_ip_payload_axis_tready;
wire        tx_ip_payload_axis_tlast, tx_ip_payload_axis_tuser;

wire        rx_udp_hdr_valid, rx_udp_hdr_ready;
wire [31:0] rx_udp_ip_source_ip;
wire [15:0] rx_udp_source_port, rx_udp_dest_port, rx_udp_length;
wire [7:0]  rx_udp_payload_axis_tdata;
wire        rx_udp_payload_axis_tvalid, rx_udp_payload_axis_tready;
wire        rx_udp_payload_axis_tlast, rx_udp_payload_axis_tuser;

wire        tx_udp_hdr_valid, tx_udp_hdr_ready;
wire [7:0]  tx_udp_payload_axis_tdata;
wire        tx_udp_payload_axis_tvalid, tx_udp_payload_axis_tready;
wire        tx_udp_payload_axis_tlast, tx_udp_payload_axis_tuser;

udp_complete #(
    .UDP_CHECKSUM_GEN_ENABLE(0),
    .ARP_CACHE_ADDR_WIDTH(2),
    // library defaults assume 125 MHz; the stack runs on 25 MHz
    .ARP_REQUEST_RETRY_INTERVAL(25_000_000*2),
    .ARP_REQUEST_TIMEOUT(25_000_000*30)
) udp_complete_inst (
    .clk(clk), .rst(rst),
    // Ethernet in / out
    .s_eth_hdr_valid(rx_eth_hdr_valid), .s_eth_hdr_ready(rx_eth_hdr_ready),
    .s_eth_dest_mac(rx_eth_dest_mac), .s_eth_src_mac(rx_eth_src_mac), .s_eth_type(rx_eth_type),
    .s_eth_payload_axis_tdata(rx_eth_payload_axis_tdata),
    .s_eth_payload_axis_tvalid(rx_eth_payload_axis_tvalid),
    .s_eth_payload_axis_tready(rx_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(rx_eth_payload_axis_tlast),
    .s_eth_payload_axis_tuser(rx_eth_payload_axis_tuser),
    .m_eth_hdr_valid(tx_eth_hdr_valid), .m_eth_hdr_ready(tx_eth_hdr_ready),
    .m_eth_dest_mac(tx_eth_dest_mac), .m_eth_src_mac(tx_eth_src_mac), .m_eth_type(tx_eth_type),
    .m_eth_payload_axis_tdata(tx_eth_payload_axis_tdata),
    .m_eth_payload_axis_tvalid(tx_eth_payload_axis_tvalid),
    .m_eth_payload_axis_tready(tx_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(tx_eth_payload_axis_tlast),
    .m_eth_payload_axis_tuser(tx_eth_payload_axis_tuser),
    // IP in (ICMP replies)
    .s_ip_hdr_valid(tx_ip_hdr_valid), .s_ip_hdr_ready(tx_ip_hdr_ready),
    .s_ip_dscp(6'd0), .s_ip_ecn(2'd0), .s_ip_length(tx_ip_length), .s_ip_ttl(tx_ip_ttl),
    .s_ip_protocol(tx_ip_protocol), .s_ip_source_ip(LOCAL_IP), .s_ip_dest_ip(tx_ip_dest_ip),
    .s_ip_payload_axis_tdata(tx_ip_payload_axis_tdata),
    .s_ip_payload_axis_tvalid(tx_ip_payload_axis_tvalid),
    .s_ip_payload_axis_tready(tx_ip_payload_axis_tready),
    .s_ip_payload_axis_tlast(tx_ip_payload_axis_tlast),
    .s_ip_payload_axis_tuser(tx_ip_payload_axis_tuser),
    // IP out (non-UDP)
    .m_ip_hdr_valid(rx_ip_hdr_valid), .m_ip_hdr_ready(rx_ip_hdr_ready),
    .m_ip_eth_dest_mac(), .m_ip_eth_src_mac(), .m_ip_eth_type(), .m_ip_version(), .m_ip_ihl(),
    .m_ip_dscp(), .m_ip_ecn(), .m_ip_length(), .m_ip_identification(), .m_ip_flags(),
    .m_ip_fragment_offset(), .m_ip_ttl(), .m_ip_protocol(rx_ip_protocol), .m_ip_header_checksum(),
    .m_ip_source_ip(rx_ip_source_ip), .m_ip_dest_ip(),
    .m_ip_payload_axis_tdata(rx_ip_payload_axis_tdata),
    .m_ip_payload_axis_tvalid(rx_ip_payload_axis_tvalid),
    .m_ip_payload_axis_tready(rx_ip_payload_axis_tready),
    .m_ip_payload_axis_tlast(rx_ip_payload_axis_tlast),
    .m_ip_payload_axis_tuser(rx_ip_payload_axis_tuser),
    // UDP in (echo replies)
    .s_udp_hdr_valid(tx_udp_hdr_valid), .s_udp_hdr_ready(tx_udp_hdr_ready),
    .s_udp_ip_dscp(6'd0), .s_udp_ip_ecn(2'd0), .s_udp_ip_ttl(8'd64),
    .s_udp_ip_source_ip(LOCAL_IP), .s_udp_ip_dest_ip(rx_udp_ip_source_ip),
    .s_udp_source_port(rx_udp_dest_port), .s_udp_dest_port(rx_udp_source_port),
    .s_udp_length(rx_udp_length), .s_udp_checksum(16'd0),
    .s_udp_payload_axis_tdata(tx_udp_payload_axis_tdata),
    .s_udp_payload_axis_tvalid(tx_udp_payload_axis_tvalid),
    .s_udp_payload_axis_tready(tx_udp_payload_axis_tready),
    .s_udp_payload_axis_tlast(tx_udp_payload_axis_tlast),
    .s_udp_payload_axis_tuser(tx_udp_payload_axis_tuser),
    // UDP out
    .m_udp_hdr_valid(rx_udp_hdr_valid), .m_udp_hdr_ready(rx_udp_hdr_ready),
    .m_udp_eth_dest_mac(), .m_udp_eth_src_mac(), .m_udp_eth_type(), .m_udp_ip_version(),
    .m_udp_ip_ihl(), .m_udp_ip_dscp(), .m_udp_ip_ecn(), .m_udp_ip_length(),
    .m_udp_ip_identification(), .m_udp_ip_flags(), .m_udp_ip_fragment_offset(), .m_udp_ip_ttl(),
    .m_udp_ip_protocol(), .m_udp_ip_header_checksum(), .m_udp_ip_source_ip(rx_udp_ip_source_ip),
    .m_udp_ip_dest_ip(), .m_udp_source_port(rx_udp_source_port), .m_udp_dest_port(rx_udp_dest_port),
    .m_udp_length(rx_udp_length), .m_udp_checksum(),
    .m_udp_payload_axis_tdata(rx_udp_payload_axis_tdata),
    .m_udp_payload_axis_tvalid(rx_udp_payload_axis_tvalid),
    .m_udp_payload_axis_tready(rx_udp_payload_axis_tready),
    .m_udp_payload_axis_tlast(rx_udp_payload_axis_tlast),
    .m_udp_payload_axis_tuser(rx_udp_payload_axis_tuser),
    // status
    .ip_rx_busy(), .ip_tx_busy(), .udp_rx_busy(), .udp_tx_busy(),
    .ip_rx_error_header_early_termination(), .ip_rx_error_payload_early_termination(),
    .ip_rx_error_invalid_header(), .ip_rx_error_invalid_checksum(),
    .ip_tx_error_payload_early_termination(), .ip_tx_error_arp_failed(),
    .udp_rx_error_header_early_termination(), .udp_rx_error_payload_early_termination(),
    .udp_tx_error_payload_early_termination(),
    // config
    .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP), .gateway_ip(GATEWAY_IP), .subnet_mask(SUBNET),
    .clear_arp_cache(1'b0)
);

// ------------------------------------------------------------------ ICMP echo
icmp_echo icmp_inst (
    .clk(clk), .rst(rst),
    .s_ip_hdr_valid(rx_ip_hdr_valid), .s_ip_hdr_ready(rx_ip_hdr_ready),
    .s_ip_protocol(rx_ip_protocol), .s_ip_source_ip(rx_ip_source_ip),
    .s_ip_payload_axis_tdata(rx_ip_payload_axis_tdata),
    .s_ip_payload_axis_tvalid(rx_ip_payload_axis_tvalid),
    .s_ip_payload_axis_tready(rx_ip_payload_axis_tready),
    .s_ip_payload_axis_tlast(rx_ip_payload_axis_tlast),
    .s_ip_payload_axis_tuser(rx_ip_payload_axis_tuser),
    .m_ip_hdr_valid(tx_ip_hdr_valid), .m_ip_hdr_ready(tx_ip_hdr_ready),
    .m_ip_length(tx_ip_length), .m_ip_ttl(tx_ip_ttl), .m_ip_protocol(tx_ip_protocol),
    .m_ip_dest_ip(tx_ip_dest_ip),
    .m_ip_payload_axis_tdata(tx_ip_payload_axis_tdata),
    .m_ip_payload_axis_tvalid(tx_ip_payload_axis_tvalid),
    .m_ip_payload_axis_tready(tx_ip_payload_axis_tready),
    .m_ip_payload_axis_tlast(tx_ip_payload_axis_tlast),
    .m_ip_payload_axis_tuser(tx_ip_payload_axis_tuser),
    .echo_count(icmp_count)
);

// ------------------------------------------------------------------ UDP echo (port UDP_PORT)
// Same pattern as the verilog-ethernet example designs: header passes straight through,
// payload goes through a FIFO so the RX side never waits on the TX header handshake.
wire match_cond = rx_udp_dest_port == UDP_PORT;
wire no_match   = !match_cond;
reg  match_cond_reg, no_match_reg;

always @(posedge clk) begin
    if (rst) begin
        match_cond_reg <= 1'b0;
        no_match_reg   <= 1'b0;
        udp_count      <= 16'd0;
    end else begin
        if (rx_udp_payload_axis_tvalid) begin
            // decide on the first payload word (the port stays valid after the header)
            if ((!match_cond_reg && !no_match_reg) ||
                (rx_udp_payload_axis_tvalid && rx_udp_payload_axis_tready && rx_udp_payload_axis_tlast)) begin
                match_cond_reg <= match_cond;
                no_match_reg   <= no_match;
            end
        end else begin
            match_cond_reg <= 1'b0;
            no_match_reg   <= 1'b0;
        end
        if (tx_udp_hdr_valid && tx_udp_hdr_ready)
            udp_count <= udp_count + 16'd1;
    end
end

assign tx_udp_hdr_valid = rx_udp_hdr_valid && match_cond;
assign rx_udp_hdr_ready = (tx_udp_hdr_ready && match_cond) || no_match;

wire [7:0] udp_fifo_in_tdata  = rx_udp_payload_axis_tdata;
wire       udp_fifo_in_tvalid = rx_udp_payload_axis_tvalid && match_cond_reg;
wire       udp_fifo_in_tready;
assign rx_udp_payload_axis_tready = (udp_fifo_in_tready && match_cond_reg) || no_match_reg;

axis_fifo #(
    .DEPTH(2048),
    .DATA_WIDTH(8),
    .KEEP_ENABLE(0),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(1),
    .USER_WIDTH(1),
    .FRAME_FIFO(0)
) udp_payload_fifo (
    .clk(clk), .rst(rst),
    .s_axis_tdata(udp_fifo_in_tdata), .s_axis_tkeep(1'b1), .s_axis_tvalid(udp_fifo_in_tvalid),
    .s_axis_tready(udp_fifo_in_tready), .s_axis_tlast(rx_udp_payload_axis_tlast),
    .s_axis_tid(8'd0), .s_axis_tdest(8'd0), .s_axis_tuser(rx_udp_payload_axis_tuser),
    .m_axis_tdata(tx_udp_payload_axis_tdata), .m_axis_tkeep(),
    .m_axis_tvalid(tx_udp_payload_axis_tvalid), .m_axis_tready(tx_udp_payload_axis_tready),
    .m_axis_tlast(tx_udp_payload_axis_tlast), .m_axis_tid(), .m_axis_tdest(),
    .m_axis_tuser(tx_udp_payload_axis_tuser),
    .status_overflow(), .status_bad_frame(), .status_good_frame()
);

endmodule

`resetall
