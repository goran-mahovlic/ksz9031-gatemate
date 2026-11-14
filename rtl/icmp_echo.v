/*
 * icmp_echo.v — ICMP echo responder on the Forencich IP interface
 *
 * Sits on the m_ip_* (non-UDP IP packets out of udp_complete) / s_ip_* (IP packets in)
 * ports. One packet at a time: the whole ICMP message is stored in a FIFO, then replayed
 * with type 8 -> 0 and the checksum fixed incrementally (RFC 1624):
 *   type byte drops by 0x08 in the high byte of word 0, so cs' = cs + 0x0800 (one's complement).
 * Anything that is not an echo request (or is received with an error) is drained.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module icmp_echo (
    input  wire        clk,
    input  wire        rst,

    // IP input (from udp_complete m_ip_*)
    input  wire        s_ip_hdr_valid,
    output wire        s_ip_hdr_ready,
    input  wire [7:0]  s_ip_protocol,
    input  wire [31:0] s_ip_source_ip,
    input  wire [7:0]  s_ip_payload_axis_tdata,
    input  wire        s_ip_payload_axis_tvalid,
    output wire        s_ip_payload_axis_tready,
    input  wire        s_ip_payload_axis_tlast,
    input  wire        s_ip_payload_axis_tuser,

    // IP output (to udp_complete s_ip_*)
    output wire        m_ip_hdr_valid,
    input  wire        m_ip_hdr_ready,
    output wire [15:0] m_ip_length,
    output wire [7:0]  m_ip_ttl,
    output wire [7:0]  m_ip_protocol,
    output wire [31:0] m_ip_dest_ip,
    output wire [7:0]  m_ip_payload_axis_tdata,
    output wire        m_ip_payload_axis_tvalid,
    input  wire        m_ip_payload_axis_tready,
    output wire        m_ip_payload_axis_tlast,
    output wire        m_ip_payload_axis_tuser,

    output reg  [15:0] echo_count
);

localparam [2:0] S_IDLE = 3'd0, S_DROP = 3'd1, S_RX = 3'd2, S_DRAIN = 3'd3,
                 S_HDR  = 3'd4, S_TX   = 3'd5;

reg [2:0]  state;
reg [31:0] peer_ip;
reg [10:0] in_idx;
reg [10:0] out_idx;
reg [10:0] plen;
reg [7:0]  b0, b2;
reg [15:0] cs_new;

wire [16:0] cs_sum = {b2, s_ip_payload_axis_tdata} + 17'h0800;

// payload FIFO (one ICMP message, max 1480 B for MTU 1500)
wire [7:0] f_in_data  = s_ip_payload_axis_tdata;
wire       f_in_valid = (state == S_RX) && s_ip_payload_axis_tvalid;
wire       f_in_ready;
wire [7:0] f_out_data;
wire       f_out_valid;
wire       f_out_last;
wire       f_out_ready;

assign s_ip_hdr_ready           = (state == S_IDLE);
assign s_ip_payload_axis_tready = (state == S_DROP) || ((state == S_RX) && f_in_ready);

assign m_ip_hdr_valid  = (state == S_HDR);
assign m_ip_length     = {5'd0, plen} + 16'd20;
assign m_ip_ttl        = 8'd64;
assign m_ip_protocol   = 8'd1;
assign m_ip_dest_ip    = peer_ip;

assign m_ip_payload_axis_tdata  = (out_idx == 11'd0) ? 8'h00 :
                                  (out_idx == 11'd2) ? cs_new[15:8] :
                                  (out_idx == 11'd3) ? cs_new[7:0] : f_out_data;
assign m_ip_payload_axis_tvalid = (state == S_TX) && f_out_valid;
assign m_ip_payload_axis_tlast  = f_out_last;
assign m_ip_payload_axis_tuser  = 1'b0;
assign f_out_ready = (state == S_DRAIN) || ((state == S_TX) && m_ip_payload_axis_tready);

axis_fifo #(
    .DEPTH(2048),
    .DATA_WIDTH(8),
    .KEEP_ENABLE(0),
    .LAST_ENABLE(1),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(0),
    .FRAME_FIFO(0)
) fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(f_in_data),
    .s_axis_tkeep(1'b1),
    .s_axis_tvalid(f_in_valid),
    .s_axis_tready(f_in_ready),
    .s_axis_tlast(s_ip_payload_axis_tlast),
    .s_axis_tid(8'd0),
    .s_axis_tdest(8'd0),
    .s_axis_tuser(1'b0),
    .m_axis_tdata(f_out_data),
    .m_axis_tkeep(),
    .m_axis_tvalid(f_out_valid),
    .m_axis_tready(f_out_ready),
    .m_axis_tlast(f_out_last),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

always @(posedge clk) begin
    if (rst) begin
        state      <= S_IDLE;
        echo_count <= 16'd0;
        in_idx     <= 11'd0;
        out_idx    <= 11'd0;
    end else begin
        case (state)
            S_IDLE: if (s_ip_hdr_valid) begin
                peer_ip <= s_ip_source_ip;
                in_idx  <= 11'd0;
                state   <= (s_ip_protocol == 8'd1) ? S_RX : S_DROP;
            end
            S_DROP: if (s_ip_payload_axis_tvalid && s_ip_payload_axis_tlast)
                state <= S_IDLE;
            S_RX: if (s_ip_payload_axis_tvalid && f_in_ready) begin
                in_idx <= in_idx + 11'd1;
                if (in_idx == 11'd0) b0 <= s_ip_payload_axis_tdata;
                if (in_idx == 11'd2) b2 <= s_ip_payload_axis_tdata;
                if (in_idx == 11'd3) cs_new <= cs_sum[15:0] + {15'd0, cs_sum[16]};
                if (s_ip_payload_axis_tlast) begin
                    plen    <= in_idx + 11'd1;
                    out_idx <= 11'd0;
                    if (!s_ip_payload_axis_tuser && b0 == 8'd8 && in_idx >= 11'd7)
                        state <= S_HDR;
                    else
                        state <= S_DRAIN;
                end
            end
            S_DRAIN: if (f_out_valid && f_out_last)
                state <= S_IDLE;
            S_HDR: if (m_ip_hdr_ready)
                state <= S_TX;
            S_TX: if (f_out_valid && m_ip_payload_axis_tready) begin
                out_idx <= out_idx + 11'd1;
                if (f_out_last) begin
                    state      <= S_IDLE;
                    echo_count <= echo_count + 16'd1;
                end
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule

`resetall
