/*
 * uart_status.v — periodic plain-text status line on the UART (115200 8N1)
 *
 * Line layout (the case list below was generated once; edit it by hand):
 *   ID=0022:1622 BMSR=796D R31=0328 RXC=05F5E RX=.... BAD=.... TX=.... ICMP=.... UDP=.... TRY=..
 * ID     : PHY reg2:reg3 at PHYAD 3 (expect 0022:1622)
 * BMSR   : reg1 (bit2 = link up, bit5 = AN complete; 796D = link + AN done)
 * R31    : KSZ9031 reg 0x1F (0x0328 = 100FD, 0x0348 = 1000FD)
 * RXC    : RXC edges/1024 per second, hex (25 MHz -> 05F5E, 125 MHz -> 1DCD6, 2.5 MHz -> 00989)
 * RX/BAD : MAC frames received good / bad FCS;  TX: frames sent
 * ICMP   : echo replies sent;  UDP: UDP echo replies;  TRY: MDIO ID retries
 * EXT=1 adds DRP (TX frames dropped), BST (TX bursts done), RD (RX frames dropped), FL (RX pairing flips)
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module uart_status #(
    parameter CLK_HZ = 50_000_000,
    parameter BAUD   = 115_200,
    parameter EXT    = 0             // 1: append " DRP=.... BST=.... RD=.. FL=.." (gbe_top)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        trigger,       // start one line (ignored while busy)
    input  wire [15:0] id1_i, id2_i, bmsr_i, phyctl_i,
    input  wire [19:0] rxcf_i,
    input  wire [15:0] rxf_i, bad_i, txf_i, icmp_i, udp_i,
    input  wire [7:0]  tries_i,
    input  wire [15:0] drp_i, bst_i,  // EXT: TX frames dropped (no space), TX bursts completed
    input  wire [7:0]  rdr_i, flp_i,  // EXT: RX frames dropped, RX nibble pairing changes
    output reg         txd
);

localparam LEN = EXT ? 124 : 94;
localparam DIV = CLK_HZ / BAUD;

reg [15:0] id1, id2, bmsr, phyctl, rxf, bad, txf, icmp, udp;
reg [19:0] rxcf;
reg [7:0]  tries;
reg [15:0] drp, bst;
reg [7:0]  rdr, flp;

function [7:0] hex;
    input [3:0] v;
    hex = (v < 4'd10) ? (8'h30 + v) : (8'h37 + v);
endfunction

// The whole line is loaded into one shift register when a line starts; each character
// is then taken from the top byte. Keeps the per-character mux out of the 50 MHz path.
reg [8*LEN-1:0] msg;
reg [7:0]       idx;
wire [7:0]      chr = msg[8*LEN-1 -: 8];

reg        busy;
reg        load;
reg [9:0]  shreg;
reg [3:0]  nbit;
reg [15:0] bcnt;

always @(posedge clk) begin
    load <= 1'b0;
    if (rst) begin
        busy <= 1'b0;
        txd  <= 1'b1;
        idx  <= 8'd0;
        nbit <= 4'd0;
        bcnt <= 16'd0;
    end else if (!busy) begin
        txd <= 1'b1;
        if (trigger) begin
            id1 <= id1_i; id2 <= id2_i; bmsr <= bmsr_i; phyctl <= phyctl_i;
            rxcf <= rxcf_i; rxf <= rxf_i; bad <= bad_i; txf <= txf_i;
            icmp <= icmp_i; udp <= udp_i; tries <= tries_i;
            drp <= drp_i; bst <= bst_i; rdr <= rdr_i; flp <= flp_i;
            load <= 1'b1;
        end
        if (load) begin
            if (EXT) begin
    msg <= {
            8'h49,
            8'h44,
            8'h3D,
            hex(id1[15:12]),
            hex(id1[11:8]),
            hex(id1[7:4]),
            hex(id1[3:0]),
            8'h3A,
            hex(id2[15:12]),
            hex(id2[11:8]),
            hex(id2[7:4]),
            hex(id2[3:0]),
            8'h20,
            8'h42,
            8'h4D,
            8'h53,
            8'h52,
            8'h3D,
            hex(bmsr[15:12]),
            hex(bmsr[11:8]),
            hex(bmsr[7:4]),
            hex(bmsr[3:0]),
            8'h20,
            8'h52,
            8'h33,
            8'h31,
            8'h3D,
            hex(phyctl[15:12]),
            hex(phyctl[11:8]),
            hex(phyctl[7:4]),
            hex(phyctl[3:0]),
            8'h20,
            8'h52,
            8'h58,
            8'h43,
            8'h3D,
            hex(rxcf[19:16]),
            hex(rxcf[15:12]),
            hex(rxcf[11:8]),
            hex(rxcf[7:4]),
            hex(rxcf[3:0]),
            8'h20,
            8'h52,
            8'h58,
            8'h3D,
            hex(rxf[15:12]),
            hex(rxf[11:8]),
            hex(rxf[7:4]),
            hex(rxf[3:0]),
            8'h20,
            8'h42,
            8'h41,
            8'h44,
            8'h3D,
            hex(bad[15:12]),
            hex(bad[11:8]),
            hex(bad[7:4]),
            hex(bad[3:0]),
            8'h20,
            8'h54,
            8'h58,
            8'h3D,
            hex(txf[15:12]),
            hex(txf[11:8]),
            hex(txf[7:4]),
            hex(txf[3:0]),
            8'h20,
            8'h49,
            8'h43,
            8'h4D,
            8'h50,
            8'h3D,
            hex(icmp[15:12]),
            hex(icmp[11:8]),
            hex(icmp[7:4]),
            hex(icmp[3:0]),
            8'h20,
            8'h55,
            8'h44,
            8'h50,
            8'h3D,
            hex(udp[15:12]),
            hex(udp[11:8]),
            hex(udp[7:4]),
            hex(udp[3:0]),
            8'h20,
            8'h54,
            8'h52,
            8'h59,
            8'h3D,
            hex(tries[7:4]),
            hex(tries[3:0]),
            8'h20,
            8'h44,
            8'h52,
            8'h50,
            8'h3D,
            hex(drp[15:12]),
            hex(drp[11:8]),
            hex(drp[7:4]),
            hex(drp[3:0]),
            8'h20,
            8'h42,
            8'h53,
            8'h54,
            8'h3D,
            hex(bst[15:12]),
            hex(bst[11:8]),
            hex(bst[7:4]),
            hex(bst[3:0]),
            8'h20,
            8'h52,
            8'h44,
            8'h3D,
            hex(rdr[7:4]),
            hex(rdr[3:0]),
            8'h20,
            8'h46,
            8'h4C,
            8'h3D,
            hex(flp[7:4]),
            hex(flp[3:0]),
            8'h0D,
            8'h0A
            };
            end else begin
            msg <= {
            8'h49,
            8'h44,
            8'h3D,
            hex(id1[15:12]),
            hex(id1[11:8]),
            hex(id1[7:4]),
            hex(id1[3:0]),
            8'h3A,
            hex(id2[15:12]),
            hex(id2[11:8]),
            hex(id2[7:4]),
            hex(id2[3:0]),
            8'h20,
            8'h42,
            8'h4D,
            8'h53,
            8'h52,
            8'h3D,
            hex(bmsr[15:12]),
            hex(bmsr[11:8]),
            hex(bmsr[7:4]),
            hex(bmsr[3:0]),
            8'h20,
            8'h52,
            8'h33,
            8'h31,
            8'h3D,
            hex(phyctl[15:12]),
            hex(phyctl[11:8]),
            hex(phyctl[7:4]),
            hex(phyctl[3:0]),
            8'h20,
            8'h52,
            8'h58,
            8'h43,
            8'h3D,
            hex(rxcf[19:16]),
            hex(rxcf[15:12]),
            hex(rxcf[11:8]),
            hex(rxcf[7:4]),
            hex(rxcf[3:0]),
            8'h20,
            8'h52,
            8'h58,
            8'h3D,
            hex(rxf[15:12]),
            hex(rxf[11:8]),
            hex(rxf[7:4]),
            hex(rxf[3:0]),
            8'h20,
            8'h42,
            8'h41,
            8'h44,
            8'h3D,
            hex(bad[15:12]),
            hex(bad[11:8]),
            hex(bad[7:4]),
            hex(bad[3:0]),
            8'h20,
            8'h54,
            8'h58,
            8'h3D,
            hex(txf[15:12]),
            hex(txf[11:8]),
            hex(txf[7:4]),
            hex(txf[3:0]),
            8'h20,
            8'h49,
            8'h43,
            8'h4D,
            8'h50,
            8'h3D,
            hex(icmp[15:12]),
            hex(icmp[11:8]),
            hex(icmp[7:4]),
            hex(icmp[3:0]),
            8'h20,
            8'h55,
            8'h44,
            8'h50,
            8'h3D,
            hex(udp[15:12]),
            hex(udp[11:8]),
            hex(udp[7:4]),
            hex(udp[3:0]),
            8'h20,
            8'h54,
            8'h52,
            8'h59,
            8'h3D,
            hex(tries[7:4]),
            hex(tries[3:0]),
            8'h0D,
            8'h0A
            };
            end
            busy <= 1'b1;
            idx  <= 8'd0;
            nbit <= 4'd0;
            bcnt <= 16'd0;
        end
    end else begin
        if (bcnt == 16'd0) begin
            if (nbit == 4'd0)
                shreg <= {1'b1, chr, 1'b0};
            else
                shreg <= {1'b1, shreg[9:1]};
            txd  <= (nbit == 4'd0) ? 1'b0 : shreg[1];
            bcnt <= DIV - 1;
            if (nbit == 4'd9) begin
                nbit <= 4'd0;
                msg  <= {msg[8*LEN-9:0], 8'h20};
                if (idx == LEN - 1)
                    busy <= 1'b0;
                else
                    idx <= idx + 8'd1;
            end else begin
                nbit <= nbit + 4'd1;
            end
        end else begin
            bcnt <= bcnt - 16'd1;
        end
    end
end

endmodule

`resetall
