`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// uart_link.v  -  PC commands for the zebra-crossing camera. Clock: clk_sys.
//
// Shares the UART with frame_capture ('c' / 'd' photo upload, unchanged): the
// link only starts a command while frame_capture is idle, and top.v hides all
// received bytes and the capture button from frame_capture while the link is
// busy (a photo's 4800 bytes may contain 'c' or 'd').
//
//   'g'            snapshot: what the network saw + its answer
//                  A5 5A 0F F1, 00 50, 00 3C, 16 info bytes, 4800 pixels, 5A A5
//   's'            status:   A5 5A 0F F2, 36 status bytes, 5A A5
//   A5 + 4800 B    classify an uploaded 80x60 photo (same protocol as the v3
//                  UART design): reply 5A, 01/00, score_hi, score_lo
//   'p' / 'r'      pause / resume camera inference: reply 'P' / 'R'
//   'v'            version string, ends with '\n'
//
// info bytes (big endian):
//   0 state (0 none, 1 not sure, 2 crossing, 3 waiting)   1 flags (b0 photo, b1 paused)
//   2-3 score   4-5 threshold   6-7 margin   8-9 averaged margin
//   10-11 camera frame   12-13 inference count   14 fps   15 b0 auto-contrast applied
// status bytes: 0-15 info, 16-17 frames committed, 18-19 frames rejected,
//   20-21 last line length, 22-23 last frame lines, 24-25 frames skipped,
//   26 camera LEDs, 27 build flags, 28 auto-contrast lo, 29 hi, 30-31 0,
//   32-35 "ZC11"
//
// A snapshot holds the BCNN engine still (snap_req / snap_ack), so the image
// and every info byte belong to the same inference. No answer within 250 ms
// -> A5 5A 0F EE 5A A5 instead. A photo upload gives up after 100 ms without a
// byte; no result within 500 ms -> 5A FF FF FF.
//------------------------------------------------------------------------------

module uart_link #(
    parameter CLK_HZ     = 133_333_333,
    parameter BANK       = 4800,
    parameter [7:0] BUILD_FLAGS = 8'h00
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        tx_busy,
    output reg  [7:0]  tx_data,
    output reg         tx_wr,
    input  wire        cap_busy,
    output wire        link_busy,

    // photo upload into frame-buffer bank 2
    output reg         inj_we,
    output reg  [13:0] inj_addr,
    output reg  [7:0]  inj_data,
    output reg         inject_tog,
    input  wire        inject_done_tog_a,
    input  wire        inj_detect_a,
    input  wire [15:0] inj_score_a,

    output reg         snap_req,
    input  wire        snap_ack_a,
    output reg         cam_pause,

    // thumbnail (image the network saw), read port on clk
    output reg  [12:0] th_raddr,
    input  wire [7:0]  th_rdata,

    // result bundle from the engine (stable while snap_ack)
    input  wire [1:0]  res_state_a,
    input  wire        res_src_a,
    input  wire        res_paused_a,
    input  wire [15:0] res_score_a,
    input  wire [15:0] res_thr_a,
    input  wire [15:0] res_margin_a,
    input  wire [15:0] res_avg_a,
    input  wire [15:0] res_frame_a,
    input  wire [15:0] res_infer_a,
    input  wire [7:0]  res_fps_a,
    input  wire [15:0] res_missed_a,
    input  wire        res_stretched_a,
    input  wire [7:0]  res_lo_a,
    input  wire [7:0]  res_hi_a,

    // camera diagnostics (this clock domain)
    input  wire [15:0] frame_cnt,
    input  wire [15:0] bad_frames,
    input  wire [10:0] last_line_len,
    input  wire [9:0]  last_lines,
    input  wire [3:0]  cam_led
);
    localparam integer T_BYTE  = CLK_HZ / 10;          // 100 ms
    localparam integer T_SNAP  = CLK_HZ / 4;           // 250 ms
    localparam integer T_INFER = CLK_HZ / 2;           // 500 ms
    localparam NPIX = BANK;

    wire snap_ack, inj_done_pulse;
    cdc_bit    u_s_ack  (.clk(clk), .d(snap_ack_a), .q(snap_ack));
    cdc_toggle u_s_done (.clk(clk), .tog(inject_done_tog_a), .pulse(inj_done_pulse));

    localparam L_IDLE = 4'd0, L_SNAPWAIT = 4'd1, L_SEND = 4'd2, L_RELEASE = 4'd3,
               L_UPLOAD = 4'd4, L_INFER = 4'd5, L_REPLY = 4'd6;
    reg [3:0]  st;
    reg [2:0]  pkt;                  // which packet L_SEND produces
    localparam P_SNAP = 3'd0, P_STATUS = 3'd1, P_ERR = 3'd2, P_INJ = 3'd3,
               P_INJ_ERR = 3'd4, P_BYTE = 3'd5, P_VERSION = 3'd6;
    reg [12:0] idx, len;
    reg [7:0]  one_byte;
    reg [26:0] timer;
    reg        holding;              // snapshot held, release afterwards

    assign link_busy = (st != L_IDLE);

    //--------------------------------------------------------------------------
    // Packet bytes
    //--------------------------------------------------------------------------
    function [7:0] info_byte;
        input [3:0] i;
        begin
            case (i)
                4'd0:  info_byte = {6'd0, res_state_a};
                4'd1:  info_byte = {6'd0, res_paused_a, res_src_a};
                4'd2:  info_byte = res_score_a[15:8];
                4'd3:  info_byte = res_score_a[7:0];
                4'd4:  info_byte = res_thr_a[15:8];
                4'd5:  info_byte = res_thr_a[7:0];
                4'd6:  info_byte = res_margin_a[15:8];
                4'd7:  info_byte = res_margin_a[7:0];
                4'd8:  info_byte = res_avg_a[15:8];
                4'd9:  info_byte = res_avg_a[7:0];
                4'd10: info_byte = res_frame_a[15:8];
                4'd11: info_byte = res_frame_a[7:0];
                4'd12: info_byte = res_infer_a[15:8];
                4'd13: info_byte = res_infer_a[7:0];
                4'd14: info_byte = res_fps_a;
                default: info_byte = {7'd0, res_stretched_a};
            endcase
        end
    endfunction

    function [7:0] status_byte;
        input [5:0] i;
        begin
            case (i)
                6'd16: status_byte = frame_cnt[15:8];
                6'd17: status_byte = frame_cnt[7:0];
                6'd18: status_byte = bad_frames[15:8];
                6'd19: status_byte = bad_frames[7:0];
                6'd20: status_byte = {5'd0, last_line_len[10:8]};
                6'd21: status_byte = last_line_len[7:0];
                6'd22: status_byte = {6'd0, last_lines[9:8]};
                6'd23: status_byte = last_lines[7:0];
                6'd24: status_byte = res_missed_a[15:8];
                6'd25: status_byte = res_missed_a[7:0];
                6'd26: status_byte = {4'd0, cam_led};
                6'd27: status_byte = BUILD_FLAGS;
                6'd28: status_byte = res_lo_a;
                6'd29: status_byte = res_hi_a;
                6'd30: status_byte = 8'h00;
                6'd31: status_byte = 8'h00;
                6'd32: status_byte = "Z";
                6'd33: status_byte = "C";
                6'd34: status_byte = "1";
                6'd35: status_byte = "1";
                default: status_byte = info_byte(i[3:0]);
            endcase
        end
    endfunction

    // "ZEBRACAM 1.1 <variant>\n"
    function [7:0] version_byte;
        input [4:0] i;
        reg [8*16-1:0] s;
        begin
            s = "ZEBRACAM 1.1 ?\n";
            // 15 characters, right-aligned in s: character i is at 8*(14-i)
            version_byte = (i == 5'd13) ? (BUILD_FLAGS[0] ? "P" : "I") : s[8*(14-i) +: 8];
        end
    endfunction

    reg [7:0] cur;      // byte at idx of the current packet
    always @(*) begin
        cur = 8'h00;
        case (pkt)
            P_SNAP: begin
                if      (idx == 0) cur = 8'hA5;
                else if (idx == 1) cur = 8'h5A;
                else if (idx == 2) cur = 8'h0F;
                else if (idx == 3) cur = 8'hF1;
                else if (idx == 4) cur = 8'h00;
                else if (idx == 5) cur = 8'd80;
                else if (idx == 6) cur = 8'h00;
                else if (idx == 7) cur = 8'd60;
                else if (idx < 24) cur = info_byte(idx[3:0] - 4'd8);
                else if (idx < 24 + NPIX) cur = th_rdata;
                else if (idx == 24 + NPIX) cur = 8'h5A;
                else cur = 8'hA5;
            end
            P_STATUS: begin
                if      (idx == 0) cur = 8'hA5;
                else if (idx == 1) cur = 8'h5A;
                else if (idx == 2) cur = 8'h0F;
                else if (idx == 3) cur = 8'hF2;
                else if (idx < 40) cur = status_byte(idx[5:0] - 6'd4);
                else if (idx == 40) cur = 8'h5A;
                else cur = 8'hA5;
            end
            P_ERR: begin
                case (idx[2:0])
                    3'd0: cur = 8'hA5; 3'd1: cur = 8'h5A; 3'd2: cur = 8'h0F;
                    3'd3: cur = 8'hEE; 3'd4: cur = 8'h5A; default: cur = 8'hA5;
                endcase
            end
            P_INJ: begin
                case (idx[1:0])
                    2'd0: cur = 8'h5A;
                    2'd1: cur = {7'd0, inj_detect_a};
                    2'd2: cur = inj_score_a[15:8];
                    default: cur = inj_score_a[7:0];
                endcase
            end
            P_INJ_ERR: cur = (idx == 0) ? 8'h5A : 8'hFF;
            P_BYTE:    cur = one_byte;
            P_VERSION: cur = version_byte(idx[4:0]);
            default:   cur = 8'h00;
        endcase
    end

    //--------------------------------------------------------------------------
    // FSM
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            st <= L_IDLE; pkt <= P_BYTE; idx <= 0; len <= 0; one_byte <= 0;
            timer <= 0; holding <= 0;
            tx_data <= 0; tx_wr <= 0;
            inj_we <= 0; inj_addr <= 0; inj_data <= 0; inject_tog <= 0;
            snap_req <= 0; cam_pause <= 0; th_raddr <= 0;
        end else begin
            tx_wr  <= 0;
            inj_we <= 0;
            th_raddr <= idx - 13'd24;           // pixel for the snapshot packet
            if (timer != 0) timer <= timer - 1'b1;

            case (st)
                L_IDLE: begin
                    holding <= 0;
                    if (rx_valid && !cap_busy) begin
                        case (rx_data)
                            "g", "s": begin
                                pkt      <= (rx_data == "g") ? P_SNAP : P_STATUS;
                                len      <= (rx_data == "g") ? 13'd24 + NPIX + 13'd2 : 13'd42;
                                snap_req <= 1;
                                timer    <= T_SNAP;
                                st       <= L_SNAPWAIT;
                            end
                            8'hA5: begin
                                idx   <= 0;
                                timer <= T_BYTE;
                                st    <= L_UPLOAD;
                            end
                            "p", "r": begin
                                cam_pause <= (rx_data == "p");
                                one_byte  <= (rx_data == "p") ? "P" : "R";
                                pkt <= P_BYTE; len <= 1; idx <= 0;
                                st  <= L_SEND;
                            end
                            "v": begin
                                pkt <= P_VERSION; len <= 15; idx <= 0;
                                st  <= L_SEND;
                            end
                            default: ;
                        endcase
                    end
                end

                // wait until the engine holds still
                L_SNAPWAIT: begin
                    if (snap_ack) begin
                        holding <= 1;
                        idx <= 0;
                        st  <= L_SEND;
                    end else if (timer == 0) begin
                        snap_req <= 0;
                        pkt <= P_ERR; len <= 6; idx <= 0;
                        st  <= L_SEND;
                    end
                end

                L_SEND: begin
                    if (!tx_busy && !tx_wr) begin
                        if (idx == len) begin
                            if (holding) begin
                                snap_req <= 0;
                                st <= L_RELEASE;
                            end else begin
                                st <= L_IDLE;
                            end
                        end else begin
                            tx_data <= cur;
                            tx_wr   <= 1;
                            idx     <= idx + 1'b1;
                        end
                    end
                end

                // let the engine see the release before another command
                L_RELEASE: begin
                    if (!snap_ack) begin
                        holding <= 0;
                        st <= L_IDLE;
                    end
                end

                // receive an 80x60 photo into bank 2
                L_UPLOAD: begin
                    if (rx_valid) begin
                        inj_we   <= 1;
                        inj_addr <= 2 * BANK + idx;
                        inj_data <= rx_data;
                        timer    <= T_BYTE;
                        if (idx == NPIX - 1) begin
                            inject_tog <= ~inject_tog;
                            timer <= T_INFER;
                            st    <= L_INFER;
                        end else begin
                            idx <= idx + 1'b1;
                        end
                    end else if (timer == 0) begin
                        st <= L_IDLE;                 // upload abandoned
                    end
                end

                L_INFER: begin
                    if (inj_done_pulse) begin
                        pkt <= P_INJ; len <= 4; idx <= 0;
                        st  <= L_SEND;
                    end else if (timer == 0) begin
                        pkt <= P_INJ_ERR; len <= 4; idx <= 0;
                        st  <= L_SEND;
                    end
                end

                default: st <= L_IDLE;
            endcase
        end
    end

endmodule
