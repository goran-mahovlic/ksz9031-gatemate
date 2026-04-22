/*
 * trace_printer.v
 *
 * Timing-friendly rewrite (2026-04-22 pass 3):
 *   - Per-event tiny ROMs (one case-function per event), each only 22-deep max.
 *   - Top-level mux selects which ROM's output we take.
 *   - 2-cycle pipeline: idx+ev -> per-ROM outputs -> muxed pipe_char -> UART FIFO.
 *
 * Accepts a one-cycle "print event" code and emits the corresponding string
 * into a uart_trace FIFO. Used to print MDIO state transitions + values.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module trace_printer #(
    parameter CLK_FREQ = 125_000_000
)(
    input  wire        clk,
    input  wire        rst,

    // Event signals (one-cycle pulse)
    input  wire        ev_boot,
    input  wire        ev_mdio_start,
    input  wire        ev_mdio_wait,
    input  wire        ev_mdio_scan,
    input  wire        ev_mdio_id,
    input  wire        ev_mdio_found,
    input  wire        ev_mdio_mmd,
    input  wire        ev_mdio_bcr,
    input  wire        ev_mdio_done,
    input  wire        ev_mdio_err,

    input  wire [4:0]  scan_addr,
    input  wire [15:0] id_val,

    // UART trace writer
    output reg  [7:0]  wr_data,
    output reg         wr_en,
    input  wire        full
);

    // ================================================================
    // Event codes
    // ================================================================
    localparam [3:0] EV_BOOT       = 4'd0;
    localparam [3:0] EV_MDIO_START = 4'd1;
    localparam [3:0] EV_MDIO_WAIT  = 4'd2;
    localparam [3:0] EV_MDIO_SCAN  = 4'd3;
    localparam [3:0] EV_MDIO_ID    = 4'd4;
    localparam [3:0] EV_MDIO_FOUND = 4'd5;
    localparam [3:0] EV_MDIO_MMD   = 4'd6;
    localparam [3:0] EV_MDIO_BCR   = 4'd7;
    localparam [3:0] EV_MDIO_DONE  = 4'd8;
    localparam [3:0] EV_MDIO_ERR   = 4'd9;
    localparam [3:0] EV_HEARTBEAT  = 4'd10;

    // ================================================================
    // 1 Hz heartbeat tick
    // ================================================================
    localparam integer HB_DIV = CLK_FREQ;
    localparam integer HB_W  = $clog2(HB_DIV);
    reg [HB_W-1:0] hb_cnt;
    reg            hb_tick;
    always @(posedge clk) begin
        if (rst) begin
            hb_cnt  <= 0;
            hb_tick <= 1'b0;
        end else if (hb_cnt == HB_DIV - 1) begin
            hb_cnt  <= 0;
            hb_tick <= 1'b1;
        end else begin
            hb_cnt  <= hb_cnt + 1'b1;
            hb_tick <= 1'b0;
        end
    end

    // ================================================================
    // Event queue (32 deep)
    // ================================================================
    localparam QAW = 5;
    localparam QD  = 32;
    reg [3:0]  q_ev  [0:QD-1];
    reg [15:0] q_pld [0:QD-1];
    reg [QAW:0] q_wptr, q_rptr;

    wire q_empty = (q_wptr == q_rptr);
    wire q_full  = ((q_wptr[QAW-1:0] == q_rptr[QAW-1:0]) &&
                    (q_wptr[QAW] != q_rptr[QAW]));

    reg [3:0]  ev_code_in;
    reg        ev_valid_in;
    reg [15:0] ev_pld_in;

    always @(*) begin
        ev_valid_in = 1'b0;
        ev_code_in  = 4'd0;
        ev_pld_in   = 16'd0;
        if (ev_boot)            begin ev_valid_in=1; ev_code_in=EV_BOOT;       end
        else if (ev_mdio_start) begin ev_valid_in=1; ev_code_in=EV_MDIO_START; end
        else if (ev_mdio_wait)  begin ev_valid_in=1; ev_code_in=EV_MDIO_WAIT;  end
        else if (ev_mdio_scan)  begin ev_valid_in=1; ev_code_in=EV_MDIO_SCAN;  ev_pld_in={11'd0, scan_addr}; end
        else if (ev_mdio_id)    begin ev_valid_in=1; ev_code_in=EV_MDIO_ID;    ev_pld_in=id_val; end
        else if (ev_mdio_found) begin ev_valid_in=1; ev_code_in=EV_MDIO_FOUND; ev_pld_in={11'd0, scan_addr}; end
        else if (ev_mdio_mmd)   begin ev_valid_in=1; ev_code_in=EV_MDIO_MMD;   end
        else if (ev_mdio_bcr)   begin ev_valid_in=1; ev_code_in=EV_MDIO_BCR;   end
        else if (ev_mdio_done)  begin ev_valid_in=1; ev_code_in=EV_MDIO_DONE;  end
        else if (ev_mdio_err)   begin ev_valid_in=1; ev_code_in=EV_MDIO_ERR;   end
        else if (hb_tick)       begin ev_valid_in=1; ev_code_in=EV_HEARTBEAT;  end
    end

    always @(posedge clk) begin
        if (rst) begin
            q_wptr <= 0;
        end else if (ev_valid_in && !q_full) begin
            q_ev[q_wptr[QAW-1:0]]  <= ev_code_in;
            q_pld[q_wptr[QAW-1:0]] <= ev_pld_in;
            q_wptr <= q_wptr + 1'b1;
        end
    end

    // ================================================================
    // String lengths per event
    // ================================================================
    function [5:0] str_len;
        input [3:0] ev;
        case (ev)
            EV_BOOT:       str_len = 6'd22;
            EV_MDIO_START: str_len = 6'd13;
            EV_MDIO_WAIT:  str_len = 6'd16;
            EV_MDIO_SCAN:  str_len = 6'd15;
            EV_MDIO_ID:    str_len = 6'd15;
            EV_MDIO_FOUND: str_len = 6'd21;
            EV_MDIO_MMD:   str_len = 6'd17;
            EV_MDIO_BCR:   str_len = 6'd17;
            EV_MDIO_DONE:  str_len = 6'd17;
            EV_MDIO_ERR:   str_len = 6'd18;
            EV_HEARTBEAT:  str_len = 6'd4;
            default:       str_len = 6'd4;
        endcase
    endfunction

    function [7:0] hex_char;
        input [3:0] nib;
        begin
            hex_char = (nib < 4'd10) ? (8'h30 + {4'd0, nib}) : (8'h41 + {4'd0, nib} - 8'd10);
        end
    endfunction

    // ================================================================
    // Per-event character functions — each is a small case statement.
    // ================================================================
    function [7:0] ch_boot; input [5:0] i; begin
        case (i)
            6'd0: ch_boot=8'h0D; 6'd1: ch_boot=8'h0A;
            6'd2: ch_boot="R"; 6'd3: ch_boot="E"; 6'd4: ch_boot="G";
            6'd5: ch_boot="O"; 6'd6: ch_boot="C"; 6'd7: ch_boot=" ";
            6'd8: ch_boot="F"; 6'd9: ch_boot="P"; 6'd10: ch_boot="G";
            6'd11: ch_boot="A"; 6'd12: ch_boot=" "; 6'd13: ch_boot="b";
            6'd14: ch_boot="o"; 6'd15: ch_boot="o"; 6'd16: ch_boot="t";
            6'd17: ch_boot="i"; 6'd18: ch_boot="n"; 6'd19: ch_boot="g";
            6'd20: ch_boot=8'h0D; 6'd21: ch_boot=8'h0A;
            default: ch_boot=" ";
        endcase
    end endfunction

    function [7:0] ch_start; input [5:0] i; begin
        case (i)
            6'd0: ch_start="M"; 6'd1: ch_start="D"; 6'd2: ch_start="I";
            6'd3: ch_start="O"; 6'd4: ch_start=":"; 6'd5: ch_start=" ";
            6'd6: ch_start="s"; 6'd7: ch_start="t"; 6'd8: ch_start="a";
            6'd9: ch_start="r"; 6'd10: ch_start="t";
            6'd11: ch_start=8'h0D; 6'd12: ch_start=8'h0A;
            default: ch_start=" ";
        endcase
    end endfunction

    function [7:0] ch_wait; input [5:0] i; begin
        case (i)
            6'd0: ch_wait="M"; 6'd1: ch_wait="D"; 6'd2: ch_wait="I";
            6'd3: ch_wait="O"; 6'd4: ch_wait=":"; 6'd5: ch_wait=" ";
            6'd6: ch_wait="w"; 6'd7: ch_wait="a"; 6'd8: ch_wait="i";
            6'd9: ch_wait="t"; 6'd10: ch_wait=" "; 6'd11: ch_wait="P";
            6'd12: ch_wait="H"; 6'd13: ch_wait="Y";
            6'd14: ch_wait=8'h0D; 6'd15: ch_wait=8'h0A;
            default: ch_wait=" ";
        endcase
    end endfunction

    function [7:0] ch_scan; input [5:0] i; input [15:0] pld; begin
        case (i)
            6'd0: ch_scan="M"; 6'd1: ch_scan="D"; 6'd2: ch_scan="I";
            6'd3: ch_scan="O"; 6'd4: ch_scan=":"; 6'd5: ch_scan=" ";
            6'd6: ch_scan="s"; 6'd7: ch_scan="c"; 6'd8: ch_scan="a";
            6'd9: ch_scan="n"; 6'd10: ch_scan=" ";
            6'd11: ch_scan=hex_char(pld[7:4]);
            6'd12: ch_scan=hex_char(pld[3:0]);
            6'd13: ch_scan=8'h0D; 6'd14: ch_scan=8'h0A;
            default: ch_scan=" ";
        endcase
    end endfunction

    function [7:0] ch_id; input [5:0] i; input [15:0] pld; begin
        case (i)
            6'd0: ch_id="M"; 6'd1: ch_id="D"; 6'd2: ch_id="I";
            6'd3: ch_id="O"; 6'd4: ch_id=":"; 6'd5: ch_id=" ";
            6'd6: ch_id="i"; 6'd7: ch_id="d"; 6'd8: ch_id="=";
            6'd9:  ch_id=hex_char(pld[15:12]);
            6'd10: ch_id=hex_char(pld[11:8]);
            6'd11: ch_id=hex_char(pld[7:4]);
            6'd12: ch_id=hex_char(pld[3:0]);
            6'd13: ch_id=8'h0D; 6'd14: ch_id=8'h0A;
            default: ch_id=" ";
        endcase
    end endfunction

    function [7:0] ch_found; input [5:0] i; input [15:0] pld; begin
        case (i)
            6'd0: ch_found="M"; 6'd1: ch_found="D"; 6'd2: ch_found="I";
            6'd3: ch_found="O"; 6'd4: ch_found=":"; 6'd5: ch_found=" ";
            6'd6: ch_found="F"; 6'd7: ch_found="O"; 6'd8: ch_found="U";
            6'd9: ch_found="N"; 6'd10: ch_found="D"; 6'd11: ch_found=" ";
            6'd12: ch_found="a"; 6'd13: ch_found="d"; 6'd14: ch_found="d";
            6'd15: ch_found="r"; 6'd16: ch_found="=";
            6'd17: ch_found=hex_char(pld[7:4]);
            6'd18: ch_found=hex_char(pld[3:0]);
            6'd19: ch_found=8'h0D; 6'd20: ch_found=8'h0A;
            default: ch_found=" ";
        endcase
    end endfunction

    function [7:0] ch_mmd; input [5:0] i; begin
        case (i)
            6'd0: ch_mmd="M"; 6'd1: ch_mmd="D"; 6'd2: ch_mmd="I";
            6'd3: ch_mmd="O"; 6'd4: ch_mmd=":"; 6'd5: ch_mmd=" ";
            6'd6: ch_mmd="m"; 6'd7: ch_mmd="m"; 6'd8: ch_mmd="d";
            6'd9: ch_mmd=" "; 6'd10: ch_mmd="w"; 6'd11: ch_mmd="r";
            6'd12: ch_mmd="i"; 6'd13: ch_mmd="t"; 6'd14: ch_mmd="e";
            6'd15: ch_mmd=8'h0D; 6'd16: ch_mmd=8'h0A;
            default: ch_mmd=" ";
        endcase
    end endfunction

    function [7:0] ch_bcr; input [5:0] i; begin
        case (i)
            6'd0: ch_bcr="M"; 6'd1: ch_bcr="D"; 6'd2: ch_bcr="I";
            6'd3: ch_bcr="O"; 6'd4: ch_bcr=":"; 6'd5: ch_bcr=" ";
            6'd6: ch_bcr="B"; 6'd7: ch_bcr="C"; 6'd8: ch_bcr="R";
            6'd9: ch_bcr=" "; 6'd10: ch_bcr="w"; 6'd11: ch_bcr="r";
            6'd12: ch_bcr="i"; 6'd13: ch_bcr="t"; 6'd14: ch_bcr="e";
            6'd15: ch_bcr=8'h0D; 6'd16: ch_bcr=8'h0A;
            default: ch_bcr=" ";
        endcase
    end endfunction

    function [7:0] ch_done; input [5:0] i; begin
        case (i)
            6'd0: ch_done="M"; 6'd1: ch_done="D"; 6'd2: ch_done="I";
            6'd3: ch_done="O"; 6'd4: ch_done=":"; 6'd5: ch_done=" ";
            6'd6: ch_done="i"; 6'd7: ch_done="n"; 6'd8: ch_done="i";
            6'd9: ch_done="t"; 6'd10: ch_done="_"; 6'd11: ch_done="d";
            6'd12: ch_done="o"; 6'd13: ch_done="n"; 6'd14: ch_done="e";
            6'd15: ch_done=8'h0D; 6'd16: ch_done=8'h0A;
            default: ch_done=" ";
        endcase
    end endfunction

    function [7:0] ch_err; input [5:0] i; begin
        case (i)
            6'd0: ch_err="M"; 6'd1: ch_err="D"; 6'd2: ch_err="I";
            6'd3: ch_err="O"; 6'd4: ch_err=":"; 6'd5: ch_err=" ";
            6'd6: ch_err="i"; 6'd7: ch_err="n"; 6'd8: ch_err="i";
            6'd9: ch_err="t"; 6'd10: ch_err="_"; 6'd11: ch_err="E";
            6'd12: ch_err="R"; 6'd13: ch_err="R"; 6'd14: ch_err="O";
            6'd15: ch_err="R";
            6'd16: ch_err=8'h0D; 6'd17: ch_err=8'h0A;
            default: ch_err=" ";
        endcase
    end endfunction

    function [7:0] ch_hb; input [5:0] i; begin
        case (i)
            6'd0: ch_hb="H"; 6'd1: ch_hb="B";
            6'd2: ch_hb=8'h0D; 6'd3: ch_hb=8'h0A;
            default: ch_hb=" ";
        endcase
    end endfunction

    // ================================================================
    // FSM state
    // ================================================================
    reg [3:0]  cur_ev;
    reg [15:0] cur_pld;
    reg [5:0]  char_idx;
    reg [2:0]  em_state;
    localparam EM_IDLE = 3'd0;
    localparam EM_LOAD = 3'd1;
    localparam EM_EMIT = 3'd2;
    localparam EM_WAIT = 3'd3;

    // ================================================================
    // Stage-1 pipeline: per-event ROM outputs (each tiny case mux)
    // Registered so each ROM's combinational depth is small.
    // ================================================================
    reg [7:0] p1_boot, p1_start, p1_wait, p1_scan, p1_id, p1_found;
    reg [7:0] p1_mmd, p1_bcr, p1_done, p1_err, p1_hb;
    reg [3:0] p1_ev;
    reg [5:0] p1_idx_max;

    always @(posedge clk) begin
        p1_boot   <= ch_boot  (char_idx);
        p1_start  <= ch_start (char_idx);
        p1_wait   <= ch_wait  (char_idx);
        p1_scan   <= ch_scan  (char_idx, cur_pld);
        p1_id     <= ch_id    (char_idx, cur_pld);
        p1_found  <= ch_found (char_idx, cur_pld);
        p1_mmd    <= ch_mmd   (char_idx);
        p1_bcr    <= ch_bcr   (char_idx);
        p1_done   <= ch_done  (char_idx);
        p1_err    <= ch_err   (char_idx);
        p1_hb     <= ch_hb    (char_idx);
        p1_ev     <= cur_ev;
        p1_idx_max <= str_len(cur_ev) - 1;
    end

    // ================================================================
    // Stage-2 mux: select which ROM we use
    // ================================================================
    reg [7:0] pipe_char;
    reg [5:0] pipe_idx_max;

    always @(posedge clk) begin
        case (p1_ev)
            EV_BOOT:       pipe_char <= p1_boot;
            EV_MDIO_START: pipe_char <= p1_start;
            EV_MDIO_WAIT:  pipe_char <= p1_wait;
            EV_MDIO_SCAN:  pipe_char <= p1_scan;
            EV_MDIO_ID:    pipe_char <= p1_id;
            EV_MDIO_FOUND: pipe_char <= p1_found;
            EV_MDIO_MMD:   pipe_char <= p1_mmd;
            EV_MDIO_BCR:   pipe_char <= p1_bcr;
            EV_MDIO_DONE:  pipe_char <= p1_done;
            EV_MDIO_ERR:   pipe_char <= p1_err;
            EV_HEARTBEAT:  pipe_char <= p1_hb;
            default:       pipe_char <= 8'h3F;  // '?'
        endcase
        pipe_idx_max <= p1_idx_max;
    end

    // ================================================================
    // Emitter FSM — 3-cycle pipeline to absorb latency
    // EM_LOAD: char_idx=0 was set last cycle; pipe_char becomes valid 2 cycles later
    // ================================================================
    reg [1:0] load_wait;

    always @(posedge clk) begin
        if (rst) begin
            q_rptr    <= 0;
            char_idx  <= 0;
            cur_ev    <= 0;
            cur_pld   <= 0;
            em_state  <= EM_IDLE;
            wr_en     <= 1'b0;
            wr_data   <= 8'd0;
            load_wait <= 2'd0;
        end else begin
            wr_en <= 1'b0;

            case (em_state)
                EM_IDLE: begin
                    if (!q_empty) begin
                        cur_ev    <= q_ev [q_rptr[QAW-1:0]];
                        cur_pld   <= q_pld[q_rptr[QAW-1:0]];
                        q_rptr    <= q_rptr + 1'b1;
                        char_idx  <= 0;
                        load_wait <= 2'd0;
                        em_state  <= EM_LOAD;
                    end
                end
                // Wait 3 cycles for the pipeline to produce the first char
                EM_LOAD: begin
                    if (load_wait == 2'd2) begin
                        em_state <= EM_EMIT;
                    end else begin
                        load_wait <= load_wait + 1'b1;
                    end
                end
                EM_EMIT: begin
                    if (!full) begin
                        wr_data <= pipe_char;
                        wr_en   <= 1'b1;
                        if (char_idx == pipe_idx_max) begin
                            em_state <= EM_IDLE;
                        end else begin
                            char_idx  <= char_idx + 1'b1;
                            load_wait <= 2'd0;
                            em_state  <= EM_WAIT;
                        end
                    end
                end
                EM_WAIT: begin
                    // 2 cycles to wait for pipeline to produce next char
                    if (load_wait == 2'd1) begin
                        em_state <= EM_EMIT;
                    end else begin
                        load_wait <= load_wait + 1'b1;
                    end
                end
                default: em_state <= EM_IDLE;
            endcase
        end
    end

endmodule

`resetall
