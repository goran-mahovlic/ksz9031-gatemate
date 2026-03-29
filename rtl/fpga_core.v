/*

Copyright (c) 2020 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * FPGA core logic
 */
module fpga_core #
(
    parameter TARGET = "GENERIC"
)
(
    /*
     * Clock: 125MHz
     * Synchronous reset
     */
    input  wire       clk,
    input  wire       rst,

    /*
     * GPIO
     */
    input  wire [1:0]  push,
    input  wire [7:0]  sw,
    output wire [7:0]  led,

    /*
     * 1GbE PHY control (KSZ9031RNXCC)
     */
    output wire MDC,
    inout  wire MDIO,
    input  wire V3_3,
    input  wire CLK_125MHZ,

    /*
     * UART
     */
    output wire txd,
    input  wire rxd,

    /*
     * Ethernet: GMII interface (from gatemate_rgmii_if)
     */
    input  wire       gmii_rx_clk,
    input  wire [7:0] gmii_rxd,
    input  wire       gmii_rx_dv,
    input  wire       gmii_rx_er,
    output wire [7:0] gmii_txd,
    output wire       gmii_tx_en,
    output wire       gmii_tx_er,
    output wire       phy0_reset_n,
    input  wire       phy0_int_n
);

// AXI between MAC and Ethernet modules
wire [7:0] rx_axis_tdata;
wire rx_axis_tvalid;
wire rx_axis_tready;
wire rx_axis_tlast;
wire rx_axis_tuser;

wire [7:0] tx_axis_tdata;
wire tx_axis_tvalid;
wire tx_axis_tready;
wire tx_axis_tlast;
wire tx_axis_tuser;

// Ethernet frame between Ethernet modules and UDP stack
wire rx_eth_hdr_ready;
wire rx_eth_hdr_valid;
wire [47:0] rx_eth_dest_mac;
wire [47:0] rx_eth_src_mac;
wire [15:0] rx_eth_type;
wire [7:0] rx_eth_payload_axis_tdata;
wire rx_eth_payload_axis_tvalid;
wire rx_eth_payload_axis_tready;
wire rx_eth_payload_axis_tlast;
wire rx_eth_payload_axis_tuser;

wire tx_eth_hdr_ready;
wire tx_eth_hdr_valid;
wire [47:0] tx_eth_dest_mac;
wire [47:0] tx_eth_src_mac;
wire [15:0] tx_eth_type;
wire [7:0] tx_eth_payload_axis_tdata;
wire tx_eth_payload_axis_tvalid;
wire tx_eth_payload_axis_tready;
wire tx_eth_payload_axis_tlast;
wire tx_eth_payload_axis_tuser;

// IP frame connections
wire rx_ip_hdr_valid;
wire rx_ip_hdr_ready;
wire [47:0] rx_ip_eth_dest_mac;
wire [47:0] rx_ip_eth_src_mac;
wire [15:0] rx_ip_eth_type;
wire [3:0] rx_ip_version;
wire [3:0] rx_ip_ihl;
wire [5:0] rx_ip_dscp;
wire [1:0] rx_ip_ecn;
wire [15:0] rx_ip_length;
wire [15:0] rx_ip_identification;
wire [2:0] rx_ip_flags;
wire [12:0] rx_ip_fragment_offset;
wire [7:0] rx_ip_ttl;
wire [7:0] rx_ip_protocol;
wire [15:0] rx_ip_header_checksum;
wire [31:0] rx_ip_source_ip;
wire [31:0] rx_ip_dest_ip;
wire [7:0] rx_ip_payload_axis_tdata;
wire rx_ip_payload_axis_tvalid;
wire rx_ip_payload_axis_tready;
wire rx_ip_payload_axis_tlast;
wire rx_ip_payload_axis_tuser;

wire tx_ip_hdr_valid;
wire tx_ip_hdr_ready;
wire [5:0] tx_ip_dscp;
wire [1:0] tx_ip_ecn;
wire [15:0] tx_ip_length;
wire [7:0] tx_ip_ttl;
wire [7:0] tx_ip_protocol;
wire [31:0] tx_ip_source_ip;
wire [31:0] tx_ip_dest_ip;
wire [7:0] tx_ip_payload_axis_tdata;
wire tx_ip_payload_axis_tvalid;
wire tx_ip_payload_axis_tready;
wire tx_ip_payload_axis_tlast;
wire tx_ip_payload_axis_tuser;

// UDP frame connections
wire rx_udp_hdr_valid;
wire rx_udp_hdr_ready;
wire [47:0] rx_udp_eth_dest_mac;
wire [47:0] rx_udp_eth_src_mac;
wire [15:0] rx_udp_eth_type;
wire [3:0] rx_udp_ip_version;
wire [3:0] rx_udp_ip_ihl;
wire [5:0] rx_udp_ip_dscp;
wire [1:0] rx_udp_ip_ecn;
wire [15:0] rx_udp_ip_length;
wire [15:0] rx_udp_ip_identification;
wire [2:0] rx_udp_ip_flags;
wire [12:0] rx_udp_ip_fragment_offset;
wire [7:0] rx_udp_ip_ttl;
wire [7:0] rx_udp_ip_protocol;
wire [15:0] rx_udp_ip_header_checksum;
wire [31:0] rx_udp_ip_source_ip;
wire [31:0] rx_udp_ip_dest_ip;
wire [15:0] rx_udp_source_port;
wire [15:0] rx_udp_dest_port;
wire [15:0] rx_udp_length;
wire [15:0] rx_udp_checksum;
wire [7:0] rx_udp_payload_axis_tdata;
wire rx_udp_payload_axis_tvalid;
wire rx_udp_payload_axis_tready;
wire rx_udp_payload_axis_tlast;
wire rx_udp_payload_axis_tuser;

wire tx_udp_hdr_valid;
wire tx_udp_hdr_ready;
wire [5:0] tx_udp_ip_dscp;
wire [1:0] tx_udp_ip_ecn;
wire [7:0] tx_udp_ip_ttl;
wire [31:0] tx_udp_ip_source_ip;
wire [31:0] tx_udp_ip_dest_ip;
wire [15:0] tx_udp_source_port;
wire [15:0] tx_udp_dest_port;
wire [15:0] tx_udp_length;
wire [15:0] tx_udp_checksum;
wire [7:0] tx_udp_payload_axis_tdata;
wire tx_udp_payload_axis_tvalid;
wire tx_udp_payload_axis_tready;
wire tx_udp_payload_axis_tlast;
wire tx_udp_payload_axis_tuser;

wire [7:0] rx_fifo_udp_payload_axis_tdata;
wire rx_fifo_udp_payload_axis_tvalid;
wire rx_fifo_udp_payload_axis_tready;
wire rx_fifo_udp_payload_axis_tlast;
wire rx_fifo_udp_payload_axis_tuser;

wire [7:0] tx_fifo_udp_payload_axis_tdata;
wire tx_fifo_udp_payload_axis_tvalid;
wire tx_fifo_udp_payload_axis_tready;
wire tx_fifo_udp_payload_axis_tlast;
wire tx_fifo_udp_payload_axis_tuser;

// Configuration
wire [47:0] local_mac   = 48'h10_e2_d5_00_00_00;
wire [31:0] local_ip    = {8'd192, 8'd168, 8'd10,  8'd150};
wire [31:0] gateway_ip  = {8'd192, 8'd168, 8'd10,  8'd1};
wire [31:0] subnet_mask = {8'd255, 8'd255, 8'd255, 8'd0};

// IP ports not used
assign rx_ip_hdr_ready = 1;
assign rx_ip_payload_axis_tready = 1;

assign tx_ip_hdr_valid = 0;
assign tx_ip_dscp = 0;
assign tx_ip_ecn = 0;
assign tx_ip_length = 0;
assign tx_ip_ttl = 0;
assign tx_ip_protocol = 0;
assign tx_ip_source_ip = 0;
assign tx_ip_dest_ip = 0;
assign tx_ip_payload_axis_tdata = 0;
assign tx_ip_payload_axis_tvalid = 0;
assign tx_ip_payload_axis_tlast = 0;
assign tx_ip_payload_axis_tuser = 0;

//udp command found

reg [31:0] n_bytes;
reg [31:0] off_cycles;
reg [31:0] pkt_n;

// Pre-computed subtraction results — removes 32-bit subtractor from critical path
reg [31:0] n_bytes_m2;
reg [31:0] off_cycles_m1;

always @ (posedge clk) begin
	if (rst) begin
	n_bytes <= 32'd1440;  //1440 bytes por paquete default;
	off_cycles <= 32'd5; // ciclos de reoloj de separacion entre paquetes, 5 por defecto
	pkt_n <= 32'd128;//por defecto ~184kB por cada pulso recibido de datos (128*8192)B = 184320B
	n_bytes_m2 <= 32'd1438;
	off_cycles_m1 <= 32'd4;
	end else begin
		if (rx_reg[63:32] == 32'h23425F40) begin // "#B_@"
			n_bytes <= rx_reg[31:0];
			n_bytes_m2 <= rx_reg[31:0] - 32'd2;
		end
		else if (rx_reg[63:32] == 32'h23505F40) begin // "#P_@"
			pkt_n <= rx_reg[31:0];
		end
		else if (rx_reg[63:32] == 32'h234F5F40) begin  // "#O_@"
			off_cycles <= rx_reg[31:0];
			off_cycles_m1 <= rx_reg[31:0] - 32'd1;
		end else begin
			n_bytes <= n_bytes;
			pkt_n <= pkt_n;
			off_cycles <= off_cycles;
		end
	end
end

//transmision de paquetes de bytes

reg [31:0] cont_reg;
reg [7:0] tx_fifo_axis_tdata;
reg [7:0] tx_fifo_axis_tdata_reg;
reg [7:0] tx_axis_tdata_test = 8'h0A; //"\n"
reg tx_fifo_axis_tvalid;
wire tx_fifo_axis_tready;
reg tx_fifo_axis_tlast;
reg tx_fifo_axis_tuser = 0; 
reg [31:0] off_cycles_reg;
reg [31:0] pkt_n_reg;
reg [2:0] state;
reg ocupado;

reg [7:0] random_data;
// Linear-feedback shift register
reg [7:0] lfsr;

wire feedback;

// Feedback
assign feedback = lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3];

// maquina de estados para trasnmision 
always @(posedge clk) begin

    if (rst) begin
        lfsr <= 8'hAB; // Semilla inicial (no todos ceros)
    end else begin
        // Generar nuevo valor cada ciclo de reloj
        lfsr[7:0] <= {lfsr[6:0], feedback};
        random_data <= lfsr;
    end

    if (rst) begin
        state <=  3'd0;
        tx_fifo_axis_tdata <= 8'd0;
        tx_fifo_axis_tdata_reg <= 8'd0;
        tx_fifo_axis_tvalid <= 0;
        cont_reg <= 32'd0;
        tx_fifo_axis_tlast <= 0;
        pkt_n_reg <= 32'd0;
        off_cycles_reg <= 32'd0;
        ocupado <= 0;
		  
    end else begin
       // Estado 0: Esperando pulso
        if (state == 3'd0) begin
        
            if ((rx_trigger && ~rx_loopb) || ocupado) begin
                ocupado <= 1; //empieza el envio de los paquetes
                state <= 3'd1;
                tx_fifo_axis_tvalid <= 1; //tvalid 1 en el siguiente ciclo
                // primera palabra del mensaje
					 if(rx_random) begin
                    tx_fifo_axis_tdata <= random_data;
                end else begin
                    tx_fifo_axis_tdata <= tx_fifo_axis_tdata_reg;
                    tx_fifo_axis_tdata_reg <= tx_fifo_axis_tdata_reg + 8'd1;
                end
            end
        end 
        // Estado 1: Enviando primera palabra del mensaje
        else if (state == 3'd1) begin
 
            if (tx_fifo_axis_tready) begin
                state <= 3'd2;
                // Primer dato aceptado y ligiendo segunda palabra
                if(rx_random) begin
                    tx_fifo_axis_tdata <= random_data;
                end else begin
                    tx_fifo_axis_tdata <= tx_fifo_axis_tdata_reg;
                    tx_fifo_axis_tdata_reg <= tx_fifo_axis_tdata_reg + 8'd1;
                end
                cont_reg <= cont_reg + 1;
            end

        end 
        // Estado 2: Enviando segunda palabra y el resto
        else if (state == 3'd2) begin
        
            if (tx_fifo_axis_tready) begin
                cont_reg <= cont_reg + 1;
                if (cont_reg == n_bytes_m2) begin
                    state <= 3'd3;
                    tx_fifo_axis_tlast <= 1;
                    pkt_n_reg <= pkt_n_reg + 1;
                end else if(rx_random) begin
                    tx_fifo_axis_tdata <= random_data;
                end else begin
                    tx_fifo_axis_tdata <= tx_fifo_axis_tdata_reg;
                    tx_fifo_axis_tdata_reg <= tx_fifo_axis_tdata_reg + 8'd1;
                end
            end

        end
        // Estado 3: Último dato del paquete
        else if (state == 3'd3) begin
        
            if (pkt_n_reg == pkt_n) begin
                cont_reg <= 0;
                pkt_n_reg <= 0;
                tx_fifo_axis_tdata_reg <= 8'd0;
                off_cycles_reg <= 32'd0;
                ocupado <= 0; //fin ocupado para volver a estado 0 y esperar otro triger
                state <= 3'd7; //si se llego al numero de mensajes ir a estado 7 para enviar uar salto de linea
                tx_fifo_axis_tlast <= 0;//bajar last en el siguiente ciclo
                tx_fifo_axis_tvalid <= 0;//bajar tvalid
            end else begin
                state <= 3'd4; //si no se llego al numero de mensaje ir al estado 4 para esperar a que baje tready
                tx_fifo_axis_tlast <= 0;//bajar last en el siguiente ciclo
                tx_fifo_axis_tvalid <= 0;//bajar tvalid
                cont_reg <= 0; //resetear cont_reg
            end
        end
         // Estado 4: esperando que tready baje para enviar otro mensaje
        else if (state == 3'd4) begin
        
            if (~tx_fifo_axis_tready) begin 
                state <= 3'd5; //cuando baje tready ir al estado 5 para esperas ciclos de separacion
            end
        end
         // Estado 5: esperando ciclos de separacion para enviar el siguiente mensaje
        else begin
        
            if (off_cycles_reg == off_cycles_m1) begin
                state <= 3'd0; // ir a estado 0
                off_cycles_reg <= 0; //reiniciando off_cycles_reg
            end else begin
                off_cycles_reg <= off_cycles_reg + 1; 
            end
        end
    end
end

wire [7:0] reg_fifo_udp_payload_axis_tdata;
wire reg_fifo_udp_payload_axis_tkeep;
wire reg_fifo_udp_payload_axis_tvalid;
wire reg_fifo_udp_payload_axis_tready;
wire reg_fifo_udp_payload_axis_tlast;
wire reg_fifo_udp_payload_axis_tuser;

//UDP config register //////////////
//como los bytes que salen de udp complete estan en little endian con este registro los ultimos 64Bytes que llegan se vuelven big endian.

reg [63:0] rx_reg; 

always @ (posedge clk) begin
	if (rst) begin
	rx_reg <= 64'd0;
	end else begin
		if (reg_fifo_udp_payload_axis_tvalid) begin
			rx_reg <= {rx_reg[55:0],reg_fifo_udp_payload_axis_tdata};
		end else begin
			rx_reg <= rx_reg;
		end
	end
end

// Loop back UDP
wire match_cond = rx_udp_dest_port == 1234;
wire no_match = !match_cond;

reg match_cond_reg = 0;
reg no_match_reg = 0;

always @(posedge clk) begin
    if (rst) begin
        match_cond_reg <= 0;
        no_match_reg <= 0;
    end else begin
        if (rx_udp_payload_axis_tvalid) begin
            if ((!match_cond_reg && !no_match_reg) ||
                (rx_udp_payload_axis_tvalid && rx_udp_payload_axis_tready && rx_udp_payload_axis_tlast)) begin
                match_cond_reg <= match_cond;
                no_match_reg <= no_match;
            end
        end else begin
				match_cond_reg <= 0;
            no_match_reg <= 0;
        end
    end
end

assign tx_udp_hdr_valid = rx_loopb ? (rx_udp_hdr_valid & match_cond) : (tx_udp_payload_axis_tvalid && tx_udp_hdr_ready);
assign rx_udp_hdr_ready = rx_loopb ? ((tx_udp_hdr_ready & match_cond) | no_match) : (match_cond | no_match);

//assign tx_udp_hdr_valid = rx_udp_hdr_valid && match_cond;
//assign rx_udp_hdr_ready = (tx_eth_hdr_ready && match_cond) || no_match;

assign tx_udp_ip_dscp = 0;
assign tx_udp_ip_ecn = 0;
assign tx_udp_ip_ttl = 64;
assign tx_udp_ip_source_ip = local_ip;

reg [31:0] tx_udp_ip_dest_ip_reg = {8'd192, 8'd168, 8'd10,  8'd18};
reg [15:0] tx_udp_source_port_reg = 16'd1234;
reg [15:0] tx_udp_dest_port_reg = 16'd9999;

assign tx_udp_ip_dest_ip = rx_loopb ? rx_udp_ip_source_ip : tx_udp_ip_dest_ip_reg;
assign tx_udp_source_port = rx_loopb ? rx_udp_dest_port : tx_udp_source_port_reg;
assign tx_udp_dest_port = rx_loopb ? rx_udp_source_port : tx_udp_dest_port_reg;

//assign tx_udp_ip_dest_ip = rx_udp_ip_source_ip;
//assign tx_udp_source_port = rx_udp_dest_port;
//assign tx_udp_dest_port = rx_udp_source_port;

assign tx_udp_length = rx_loopb ? rx_udp_length : (n_bytes[15:0] + 16'd8);
assign tx_udp_checksum = 0;

assign tx_udp_payload_axis_tdata = rx_loopb ? reg_fifo_udp_payload_axis_tdata : tx_fifo_axis_tdata;
assign tx_udp_payload_axis_tvalid = rx_loopb ? reg_fifo_udp_payload_axis_tvalid : tx_fifo_axis_tvalid;
assign tx_fifo_axis_tready = tx_udp_payload_axis_tready;
assign reg_fifo_udp_payload_axis_tready = rx_loopb ? tx_udp_payload_axis_tready : 1'b1;
assign tx_udp_payload_axis_tlast = rx_loopb ? reg_fifo_udp_payload_axis_tlast : tx_fifo_axis_tlast;
assign tx_udp_payload_axis_tuser = rx_loopb ? reg_fifo_udp_payload_axis_tuser : tx_fifo_axis_tuser;

//assign tx_udp_payload_axis_tdata = tx_fifo_udp_payload_axis_tdata;
//assign tx_udp_payload_axis_tvalid = tx_fifo_udp_payload_axis_tvalid;
//assign tx_fifo_udp_payload_axis_tready = tx_udp_payload_axis_tready;
//assign tx_udp_payload_axis_tlast  = tx_fifo_udp_payload_axis_tlast;
//assign tx_udp_payload_axis_tuser = tx_fifo_udp_payload_axis_tuser;

assign rx_fifo_udp_payload_axis_tdata = rx_udp_payload_axis_tdata;
assign rx_fifo_udp_payload_axis_tvalid = rx_udp_payload_axis_tvalid && match_cond_reg;
assign rx_udp_payload_axis_tready = (rx_fifo_udp_payload_axis_tready && match_cond_reg) || no_match_reg;
assign rx_fifo_udp_payload_axis_tlast = rx_udp_payload_axis_tlast;
assign rx_fifo_udp_payload_axis_tuser = rx_udp_payload_axis_tuser;


assign phy0_reset_n = ~rst && ~push[0] && sw[0]; // desactivar phy con sw[0], reset con push[0]

gm_eth_mac_1g_fifo #(
    .ENABLE_PADDING(1),
    .MIN_FRAME_LENGTH(64),
    .TX_FIFO_DEPTH(64),
    .TX_FRAME_FIFO(1),
    .RX_FIFO_DEPTH(64),
    .RX_FRAME_FIFO(1)
)
eth_mac_inst (
    .rx_clk(gmii_rx_clk),
    .rx_rst(rst),
    .tx_clk(clk),
    .tx_rst(rst),
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
    .tx_clk_enable(1'b1),
    .rx_mii_select(1'b0),
    .tx_mii_select(1'b0),

    .tx_error_underflow(),
    .tx_fifo_overflow(),
    .tx_fifo_bad_frame(),
    .tx_fifo_good_frame(),
    .rx_error_bad_frame(),
    .rx_error_bad_fcs(),
    .rx_fifo_overflow(),
    .rx_fifo_bad_frame(),
    .rx_fifo_good_frame(),

    .cfg_ifg(8'd12),
    .cfg_tx_enable(1'b1),
    .cfg_rx_enable(1'b1)
);

eth_axis_rx
eth_axis_rx_inst (
    .clk(clk),
    .rst(rst),
    // AXI input
    .s_axis_tdata(rx_axis_tdata),
    .s_axis_tvalid(rx_axis_tvalid),
    .s_axis_tready(rx_axis_tready),
    .s_axis_tlast(rx_axis_tlast),
    .s_axis_tuser(rx_axis_tuser),
    // Ethernet frame output
    .m_eth_hdr_valid(rx_eth_hdr_valid),
    .m_eth_hdr_ready(rx_eth_hdr_ready),
    .m_eth_dest_mac(rx_eth_dest_mac),
    .m_eth_src_mac(rx_eth_src_mac),
    .m_eth_type(rx_eth_type),
    .m_eth_payload_axis_tdata(rx_eth_payload_axis_tdata),
    .m_eth_payload_axis_tvalid(rx_eth_payload_axis_tvalid),
    .m_eth_payload_axis_tready(rx_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(rx_eth_payload_axis_tlast),
    .m_eth_payload_axis_tuser(rx_eth_payload_axis_tuser),
    // Status signals
    .busy(),
    .error_header_early_termination()
);

eth_axis_tx
eth_axis_tx_inst (
    .clk(clk),
    .rst(rst),
    // Ethernet frame input
    .s_eth_hdr_valid(tx_eth_hdr_valid),
    .s_eth_hdr_ready(tx_eth_hdr_ready),
    .s_eth_dest_mac(tx_eth_dest_mac),
    .s_eth_src_mac(tx_eth_src_mac),
    .s_eth_type(tx_eth_type),
    .s_eth_payload_axis_tdata(tx_eth_payload_axis_tdata),
    .s_eth_payload_axis_tvalid(tx_eth_payload_axis_tvalid),
    .s_eth_payload_axis_tready(tx_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(tx_eth_payload_axis_tlast),
    .s_eth_payload_axis_tuser(tx_eth_payload_axis_tuser),
    // AXI output
    .m_axis_tdata(tx_axis_tdata),
    .m_axis_tvalid(tx_axis_tvalid),
    .m_axis_tready(tx_axis_tready),
    .m_axis_tlast(tx_axis_tlast),
    .m_axis_tuser(tx_axis_tuser),
    // Status signals
    .busy()
);

udp_complete #(
    .UDP_CHECKSUM_GEN_ENABLE(0),
    .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(8),
    .ARP_CACHE_ADDR_WIDTH(2)
)
udp_complete_inst (
    .clk(clk),
    .rst(rst),
    // Ethernet frame input
    .s_eth_hdr_valid(rx_eth_hdr_valid),
    .s_eth_hdr_ready(rx_eth_hdr_ready),
    .s_eth_dest_mac(rx_eth_dest_mac),
    .s_eth_src_mac(rx_eth_src_mac),
    .s_eth_type(rx_eth_type),
    .s_eth_payload_axis_tdata(rx_eth_payload_axis_tdata),
    .s_eth_payload_axis_tvalid(rx_eth_payload_axis_tvalid),
    .s_eth_payload_axis_tready(rx_eth_payload_axis_tready),
    .s_eth_payload_axis_tlast(rx_eth_payload_axis_tlast),
    .s_eth_payload_axis_tuser(rx_eth_payload_axis_tuser),
    // Ethernet frame output
    .m_eth_hdr_valid(tx_eth_hdr_valid),
    .m_eth_hdr_ready(tx_eth_hdr_ready),
    .m_eth_dest_mac(tx_eth_dest_mac),
    .m_eth_src_mac(tx_eth_src_mac),
    .m_eth_type(tx_eth_type),
    .m_eth_payload_axis_tdata(tx_eth_payload_axis_tdata),
    .m_eth_payload_axis_tvalid(tx_eth_payload_axis_tvalid),
    .m_eth_payload_axis_tready(tx_eth_payload_axis_tready),
    .m_eth_payload_axis_tlast(tx_eth_payload_axis_tlast),
    .m_eth_payload_axis_tuser(tx_eth_payload_axis_tuser),
    // IP frame input
    .s_ip_hdr_valid(tx_ip_hdr_valid),
    .s_ip_hdr_ready(tx_ip_hdr_ready),
    .s_ip_dscp(tx_ip_dscp),
    .s_ip_ecn(tx_ip_ecn),
    .s_ip_length(tx_ip_length),
    .s_ip_ttl(tx_ip_ttl),
    .s_ip_protocol(tx_ip_protocol),
    .s_ip_source_ip(tx_ip_source_ip),
    .s_ip_dest_ip(tx_ip_dest_ip),
    .s_ip_payload_axis_tdata(tx_ip_payload_axis_tdata),
    .s_ip_payload_axis_tvalid(tx_ip_payload_axis_tvalid),
    .s_ip_payload_axis_tready(tx_ip_payload_axis_tready),
    .s_ip_payload_axis_tlast(tx_ip_payload_axis_tlast),
    .s_ip_payload_axis_tuser(tx_ip_payload_axis_tuser),
    // IP frame output
    .m_ip_hdr_valid(rx_ip_hdr_valid),
    .m_ip_hdr_ready(rx_ip_hdr_ready),
    .m_ip_eth_dest_mac(rx_ip_eth_dest_mac),
    .m_ip_eth_src_mac(rx_ip_eth_src_mac),
    .m_ip_eth_type(rx_ip_eth_type),
    .m_ip_version(rx_ip_version),
    .m_ip_ihl(rx_ip_ihl),
    .m_ip_dscp(rx_ip_dscp),
    .m_ip_ecn(rx_ip_ecn),
    .m_ip_length(rx_ip_length),
    .m_ip_identification(rx_ip_identification),
    .m_ip_flags(rx_ip_flags),
    .m_ip_fragment_offset(rx_ip_fragment_offset),
    .m_ip_ttl(rx_ip_ttl),
    .m_ip_protocol(rx_ip_protocol),
    .m_ip_header_checksum(rx_ip_header_checksum),
    .m_ip_source_ip(rx_ip_source_ip),
    .m_ip_dest_ip(rx_ip_dest_ip),
    .m_ip_payload_axis_tdata(rx_ip_payload_axis_tdata),
    .m_ip_payload_axis_tvalid(rx_ip_payload_axis_tvalid),
    .m_ip_payload_axis_tready(rx_ip_payload_axis_tready),
    .m_ip_payload_axis_tlast(rx_ip_payload_axis_tlast),
    .m_ip_payload_axis_tuser(rx_ip_payload_axis_tuser),
    // UDP frame input
    .s_udp_hdr_valid(tx_udp_hdr_valid),
    .s_udp_hdr_ready(tx_udp_hdr_ready),
    .s_udp_ip_dscp(tx_udp_ip_dscp),
    .s_udp_ip_ecn(tx_udp_ip_ecn),
    .s_udp_ip_ttl(tx_udp_ip_ttl),
    .s_udp_ip_source_ip(local_ip),
    .s_udp_ip_dest_ip(tx_udp_ip_dest_ip),
    .s_udp_source_port(tx_udp_source_port),
    .s_udp_dest_port(tx_udp_dest_port),
    .s_udp_length(tx_udp_length),
    .s_udp_checksum(tx_udp_checksum),
    .s_udp_payload_axis_tdata(tx_udp_payload_axis_tdata),
    .s_udp_payload_axis_tvalid(tx_udp_payload_axis_tvalid),
    .s_udp_payload_axis_tready(tx_udp_payload_axis_tready),
    .s_udp_payload_axis_tlast(tx_udp_payload_axis_tlast),
    .s_udp_payload_axis_tuser(tx_udp_payload_axis_tuser),
    // UDP frame output
    .m_udp_hdr_valid(rx_udp_hdr_valid),
    .m_udp_hdr_ready(rx_udp_hdr_ready),
    .m_udp_eth_dest_mac(rx_udp_eth_dest_mac),
    .m_udp_eth_src_mac(rx_udp_eth_src_mac),
    .m_udp_eth_type(rx_udp_eth_type),
    .m_udp_ip_version(rx_udp_ip_version),
    .m_udp_ip_ihl(rx_udp_ip_ihl),
    .m_udp_ip_dscp(rx_udp_ip_dscp),
    .m_udp_ip_ecn(rx_udp_ip_ecn),
    .m_udp_ip_length(rx_udp_ip_length),
    .m_udp_ip_identification(rx_udp_ip_identification),
    .m_udp_ip_flags(rx_udp_ip_flags),
    .m_udp_ip_fragment_offset(rx_udp_ip_fragment_offset),
    .m_udp_ip_ttl(rx_udp_ip_ttl),
    .m_udp_ip_protocol(rx_udp_ip_protocol),
    .m_udp_ip_header_checksum(rx_udp_ip_header_checksum),
    .m_udp_ip_source_ip(rx_udp_ip_source_ip),
    .m_udp_ip_dest_ip(rx_udp_ip_dest_ip),
    .m_udp_source_port(rx_udp_source_port),
    .m_udp_dest_port(rx_udp_dest_port),
    .m_udp_length(rx_udp_length),
    .m_udp_checksum(rx_udp_checksum),
    .m_udp_payload_axis_tdata(rx_udp_payload_axis_tdata),
    .m_udp_payload_axis_tvalid(rx_udp_payload_axis_tvalid),
    .m_udp_payload_axis_tready(rx_udp_payload_axis_tready),
    .m_udp_payload_axis_tlast(rx_udp_payload_axis_tlast),
    .m_udp_payload_axis_tuser(rx_udp_payload_axis_tuser),
    // Status signals
    .ip_rx_busy(),
    .ip_tx_busy(),
    .udp_rx_busy(),
    .udp_tx_busy(),
    .ip_rx_error_header_early_termination(),
    .ip_rx_error_payload_early_termination(),
    .ip_rx_error_invalid_header(),
    .ip_rx_error_invalid_checksum(),
    .ip_tx_error_payload_early_termination(),
    .ip_tx_error_arp_failed(),
    .udp_rx_error_header_early_termination(),
    .udp_rx_error_payload_early_termination(),
    .udp_tx_error_payload_early_termination(),
    // Configuration
    .local_mac(local_mac),
    .local_ip(local_ip),
    .gateway_ip(gateway_ip),
    .subnet_mask(subnet_mask),
    .clear_arp_cache(0)
	 
);

axis_fifo #(
    .DEPTH(64),
    .DATA_WIDTH(8),
    .KEEP_ENABLE(0),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(1),
    .USER_WIDTH(1),
    .FRAME_FIFO(1)
)
udp_payload_fifo (
    .clk(clk),
    .rst(rst),

    // AXI input
    .s_axis_tdata(rx_fifo_udp_payload_axis_tdata),
    .s_axis_tkeep(0),
    .s_axis_tvalid(rx_fifo_udp_payload_axis_tvalid),
    .s_axis_tready(rx_fifo_udp_payload_axis_tready),
    .s_axis_tlast(rx_fifo_udp_payload_axis_tlast),
    .s_axis_tid(0),
    .s_axis_tdest(0),
    .s_axis_tuser(rx_fifo_udp_payload_axis_tuser),

    // AXI output
    .m_axis_tdata(reg_fifo_udp_payload_axis_tdata),
    .m_axis_tkeep(),
    .m_axis_tvalid(reg_fifo_udp_payload_axis_tvalid),
    .m_axis_tready(reg_fifo_udp_payload_axis_tready),
    .m_axis_tlast(reg_fifo_udp_payload_axis_tlast),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(reg_fifo_udp_payload_axis_tuser),

    // Status
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

//LED RUN STATUS////////////////////////////////////////////////////////////

assign led[0] = ~rst && sw[1]; //reset_n global encendido cuando run
assign led[1] = phy0_reset_n && sw[1]; //reset_n phy encendido cuando run
assign led[2] = CLK_125MHZ && sw[2];
assign led[3] = ~phy0_int_n && sw[3];

//UART/////////////////////////////////////////////////////////

wire rx_busy;
wire tx_busy;

assign led[6] = ocupado && sw[6]; //desactivar indicador con sw

uart uart_inst (
	  .clk(clk),
	  .reset_n(rst || push[1]),
	  .tx_ena(tx_ena),
	  .tx_data(tx_data),
	  .rx(rxd),
	  .rx_busy(rx_busy),
	  .rx_error(),
	  .rx_data(rx_data_s),
	  .tx_busy(tx_busy),
	  .tx(txd)
);

///////UART RX////////////////////////////////////////////////////

wire [7:0] rx_data_s;
reg [7:0] rx_data_reg;

reg [2:0] state_uart = 2'd0;
reg rx_valid; // pulso para leer rx data

always @(posedge clk) begin
    if (rst) begin
        rx_valid <= 0;
		  rx_data_reg <= 8'd0;
		  state_uart <= 2'd0;
    end else begin
			//estado 0: esperando rx busy
        if (state_uart == 2'd0) begin 
				if (rx_busy) begin
					state_uart <= 2'd1; //pasando a estado 1 cuando rx_busy suba
				end
        end
			//estado 1: esperando a que baje rx_busy
		  else if (state_uart == 2'd1) begin
				if (~rx_busy) begin
					rx_data_reg <= rx_data_s; //guardar por un ciclo en reg
					rx_valid <= 1; //subir valid cuando rx_busy baje
					state_uart <= 2'd2; // pasar a estado 2
				end
        end 
		  else begin
				rx_data_reg <= 8'd0; // borrar registro 
				rx_valid <= 0; //bajar valid 
				state_uart <= 2'd0; // volver a estado 0 a esperar otro rx_busy
		  end
    end
end

//UDP CONTROL/////////////////////////////
//loopback///////////////////////////
reg rx_loopb;

always @(posedge clk) begin
    if (rst) begin
        rx_loopb <= 0;
    end else begin
        if (rx_data_reg == 8'h4C) begin //L
				rx_loopb <= ~rx_loopb;
        end else begin
				rx_loopb <= rx_loopb;
		  end
    end
end

assign led[4] = rx_loopb && sw[4]; //decarctivar indicador con sw

////////////////////////////////////////////////////////////
reg rx_trigger;

always @(posedge clk) begin
    if (rst) begin
        rx_trigger <= 0;
    end else begin
        if (rx_data_reg == 8'h54) begin //T
				rx_trigger <= 1; //pulse with a single T
        end else if (rx_trigger == 1) begin
				rx_trigger <= 0;
		  end else begin
				rx_trigger <= rx_trigger;
		  end
    end
end

////////////////////////////////////////////////////////////
reg rx_random;

always @(posedge clk) begin
    if (rst) begin
        rx_random <= 0;
    end else begin
        if (rx_data_reg == 8'h52) begin //R
				rx_random <= ~rx_random;
        end else begin
				rx_random <= rx_random;
		  end
    end
end

assign led[5] = rx_random && sw[5];

// MDIO Auto-Init FSM ////////////////////////////////////////////////////////
// Init FSM has priority on MDIO bus until init_done is asserted.
// After init_done, UART-driven MDIO controls take over.

wire        init_mdio_start;
wire        init_mdio_rw;
wire [4:0]  init_mdio_phy;
wire [4:0]  init_mdio_reg;
wire [15:0] init_mdio_wdata;
wire        init_done;
wire        init_error;
wire [15:0] phy_id_debug;

mdio_init #(
    .PHY_ADDR(5'd7)
) mdio_init_inst (
    .clk(clk),
    .rst(rst),
    .phy_ready(phy0_reset_n),
    .mdio_start(init_mdio_start),
    .mdio_rw(init_mdio_rw),
    .mdio_phy(init_mdio_phy),
    .mdio_reg(init_mdio_reg),
    .mdio_wdata(init_mdio_wdata),
    .mdio_rdata(mdio_rdata),
    .mdio_busy(mdio_busy),
    .mdio_rvalid(mdio_rvalid),
    .init_done(init_done),
    .init_error(init_error),
    .phy_id(phy_id_debug)
);

// MDIO bus mux: init FSM has priority until init_done
wire        muxed_mdio_start = init_done ? mdio_start      : init_mdio_start;
wire        muxed_mdio_rw    = init_done ? mdio_op         : init_mdio_rw;
wire [4:0]  muxed_mdio_phy   = init_done ? mdio_phy        : init_mdio_phy;
wire [4:0]  muxed_mdio_reg   = init_done ? mdio_reg        : init_mdio_reg;
wire [15:0] muxed_mdio_wdata = init_done ? mdio_wdata      : init_mdio_wdata;

// PHY CONTROLLER (UART-driven, active after init_done)
/*------------------*/
reg mdio_op;

always @(posedge clk) begin
    if (rst) begin
        mdio_op <= 1; //default read
    end else begin
        if (rx_data_reg == 8'h77) begin //w for write
				mdio_op <= 0;
        end else if (rx_data_reg == 8'h72) begin //r for read
				mdio_op <= 1;
        end else begin
				mdio_op <= mdio_op;
		  end
    end
end
/*------------------*/
reg [4:0] mdio_phy;

always @(posedge clk) begin
    if (rst) begin
        mdio_phy <= 5'b00111; // default 7
    end else begin
        if (rx_data_reg[7:5] == 3'b001) begin //8'b001AAAAA 
				mdio_phy <= rx_data_reg[4:0];
        end else begin
				mdio_phy <= mdio_phy;
		  end
    end
end
/*------------------*/
reg [4:0] mdio_reg;

always @(posedge clk) begin
    if (rst) begin
        mdio_reg <= 5'd0; // default 0
    end else begin
        if (rx_data_reg[7:5] == 3'b100) begin //8'b100RRRRR
				mdio_reg <= rx_data_reg[4:0];
        end else begin
				mdio_reg <= mdio_reg;
		  end
    end
end
/*------------------*/
reg [15:0] mdio_wdata;
reg [2:0] state_wdata = 2'd0;

always @(posedge clk) begin
    if (rst) begin
		  mdio_wdata <= 16'd0;
		  state_wdata <= 2'd0;
    end else begin
			//estado 0: esperando 'd' por uart
        if (state_wdata == 2'd0) begin
				if (rx_data_reg == 8'h64) begin
					state_wdata <= 2'd1; //pasando a estado 1 cuando se reciba 'd'
				end
        end
			//estado 1: esperando valid 
		  else if (state_wdata == 2'd1) begin
				if (rx_valid) begin
					mdio_wdata <= {rx_data_reg, mdio_wdata[7:0]}; // primero msByte
					state_wdata <= 2'd2; // pasar a estado 2
				end
        end 
		  else if (state_wdata == 2'd2) begin
				if (rx_valid) begin
					mdio_wdata <= {mdio_wdata[15:8], rx_data_reg}; //luego lsByte
					state_wdata <= 2'd3; // pasar a estado 3
				end
		  end
		  else begin
				mdio_wdata <= mdio_wdata; // mantener valor 
				state_wdata <= 2'd0; // pasar a estado 0
		  end
    end
end
/*------------------*/
reg mdio_start;

always @(posedge clk) begin
    if (rst) begin
        mdio_start <= 0;
    end else begin
        if (rx_data_reg == 8'h73) begin //s
				mdio_start <= 1; //pulse with a single s
        end else if (mdio_start == 1) begin
				mdio_start <= 0;
		  end else begin
				mdio_start <= mdio_start;
		  end
    end
end

/*------------------*/
wire mdio_busy;
assign led[7]= mdio_busy && sw[7];

mdio_controller
mdio_controller_inst(
    // System Signals
    .clk(clk),
    .rst_n(~rst && ~push[1]),

    // User Interface - Inputs (muxed: init FSM or UART)
    .start(muxed_mdio_start),
    .rw(muxed_mdio_rw),
    .phy_addr(muxed_mdio_phy),
    .reg_addr(muxed_mdio_reg),
    .wdata(muxed_mdio_wdata),

    // User Interface - Outputs
    .rdata(mdio_rdata),      // Data read from PHY 16b
    .busy(mdio_busy),       // Controller is busy
    .rvalid(mdio_rvalid),     // Read data is valid

    // PHY Interface
    .mdc(MDC),        // MDIO Clock
    .mdio(MDIO)        // MDIO Data
);

//SEND READ DATA REGISTERS//////////////////////////////////////
wire [15:0] mdio_rdata;
reg [15:0] mdio_rdata_reg;
wire mdio_rvalid;
reg mdio_read_ready;

always @(posedge clk) begin
    if (rst) begin
        mdio_rdata_reg <= 16'd0;
		  mdio_read_ready <= 0;
    end else begin
        if (mdio_rvalid) begin //si mdio valid
				mdio_rdata_reg <= mdio_rdata; //guardar registro
				mdio_read_ready <= 1;
		  end else begin
				mdio_rdata_reg <= mdio_rdata_reg;
				mdio_read_ready <= 0;
		  end
    end
end

//UART TX////////////////////////////////////
reg tx_ena;
reg [7:0] tx_data;
reg [2:0] state_uart_tx = 2'd0;

always @(posedge clk) begin
    if (rst) begin
		  tx_ena <= 0;
		  tx_data <= 8'd0;
		  state_uart_tx <= 2'd0;
    end else begin
			//estado 0: esperando mdio_read_ready
        if (state_uart_tx == 2'd0) begin
				if (mdio_read_ready) begin
					tx_data <= mdio_rdata_reg[15:8];
					tx_ena <= 1;
					state_uart_tx <= 2'd1;
				end
        end
			//estado 1
		  else if (state_uart_tx == 2'd1) begin
				tx_ena <= 0;
				state_uart_tx <= 2'd2; // pasar a estado 2
        end 
		  //estado 2: esperando a que se envie primero 8 bits
		  else if (state_uart_tx == 2'd2) begin
				if (~tx_busy) begin
					tx_data <= mdio_rdata_reg[7:0];
					tx_ena <= 1;
					state_uart_tx <= 2'd3; // pasar a estado 3
				end
		  end
		  //estado 3: esperar a que se envie segunda palabra para volver a estado 0
		  else begin
				tx_ena <= 0; 
				if (~tx_busy) begin
				state_uart_tx <= 2'd0; // pasar a estado 0
				end
		  end
    end
end

endmodule
`resetall
