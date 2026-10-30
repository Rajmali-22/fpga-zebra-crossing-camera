`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// status_text.v  -  the two 16-character lines shown on the LCD and the VGA
// overlay, rebuilt after every result (and every 100 ms). Clock: clk_core.
//
//   line 1: ZEBRA CROSSING! / NOT SURE / NO CROSSING / WAITING CAMERA / PAUSED BY PC
//   line 2: S503 M+026 13FPS   (camera: score, margin, inferences per second)
//           PHOTO S503 M+026   (result of a photo uploaded from the PC)
// Character 0 is in bits [127:120].
//------------------------------------------------------------------------------

module status_text #(
    parameter CLK_HZ = 50_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        res_tog,
    input  wire [1:0]  res_state,
    input  wire        res_src,
    input  wire        res_paused,
    input  wire [15:0] res_score,
    input  wire signed [15:0] res_margin,
    input  wire [7:0]  res_fps,
    input  wire [15:0] res_thr,
    output reg  [127:0] line1,
    output reg  [127:0] line2,
    output reg  [1:0]  o_state,       // published with the text, for the overlay
    output reg  [15:0] o_score,
    output reg  [15:0] o_thr,
    output reg         text_tog       // flips when all of the above changed; they
                                      // then stay put for at least 5 us
);
    reg        tog_d;
    reg [23:0] tick;
    wire       refresh = (tick == CLK_HZ / 10 - 1);

    localparam T_IDLE = 2'd0, T_CONV = 2'd1, T_BUILD = 2'd2, T_GUARD = 2'd3;
    reg [7:0]  guard;
    reg [1:0]  st;
    reg [1:0]  which;          // 0 score, 1 |margin|, 2 fps
    reg [9:0]  v;
    reg [3:0]  d2, d1;         // hundreds, tens of the number being converted
    reg [3:0]  s_h, s_t, s_o, m_h, m_t, m_o, f_t, f_o;
    reg        m_neg;
    reg [1:0]  c_state;
    reg        c_src, c_paused;
    reg [15:0] c_score, c_thr;
    reg signed [15:0] c_margin;
    reg [7:0]  c_fps;

    function [7:0] dig;
        input [3:0] d;
        dig = 8'h30 + d;
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            tog_d <= 0; tick <= 0; st <= T_IDLE; which <= 0; v <= 0; d2 <= 0; d1 <= 0;
            {s_h, s_t, s_o, m_h, m_t, m_o, f_t, f_o} <= 0; m_neg <= 0;
            c_state <= 2'd3; c_src <= 0; c_paused <= 0; c_score <= 0; c_margin <= 0; c_fps <= 0;
            c_thr <= 0; o_state <= 2'd3; o_score <= 0; o_thr <= 0; guard <= 0;
            line1 <= "WAITING CAMERA  ";
            line2 <= "S--- M---- --FPS";
            text_tog <= 0;
        end else begin
            tog_d <= res_tog;
            tick  <= refresh ? 24'd0 : tick + 1'b1;

            case (st)
                T_IDLE: if (res_tog != tog_d || refresh) begin
                    c_state  <= res_state;
                    c_src    <= res_src;
                    c_paused <= res_paused;
                    c_score  <= res_score;
                    c_thr    <= res_thr;
                    c_margin <= res_margin;
                    c_fps    <= res_fps;
                    m_neg    <= res_margin < 0;
                    v        <= (res_score > 999) ? 10'd999 : res_score[9:0];
                    which    <= 0;
                    d2 <= 0; d1 <= 0;
                    st <= T_CONV;
                end

                // repeated subtraction: hundreds, then tens; the rest are ones
                T_CONV: begin
                    if (v >= 100)      begin v <= v - 10'd100; d2 <= d2 + 1'b1; end
                    else if (v >= 10)  begin v <= v - 10'd10;  d1 <= d1 + 1'b1; end
                    else begin
                        case (which)
                            2'd0: begin
                                s_h <= d2; s_t <= d1; s_o <= v[3:0];
                                which <= 1;
                                v <= (c_margin < 0) ? ((-c_margin > 999) ? 10'd999 : -c_margin)
                                                    : ((c_margin > 999) ? 10'd999 : c_margin[9:0]);
                            end
                            2'd1: begin
                                m_h <= d2; m_t <= d1; m_o <= v[3:0];
                                which <= 2;
                                v <= (c_fps > 99) ? 10'd99 : {2'b0, c_fps};
                            end
                            default: begin
                                f_t <= d1; f_o <= v[3:0];
                                st <= T_BUILD;
                            end
                        endcase
                        d2 <= 0; d1 <= 0;
                    end
                end

                T_BUILD: begin
                    if (c_paused && !c_src)  line1 <= "PAUSED BY PC    ";
                    else case (c_state)
                        2'd2:    line1 <= "ZEBRA CROSSING! ";
                        2'd1:    line1 <= "NOT SURE        ";
                        2'd0:    line1 <= "NO CROSSING     ";
                        default: line1 <= "WAITING CAMERA  ";
                    endcase
                    if (c_src)
                        line2 <= {"PHOTO S", dig(s_h), dig(s_t), dig(s_o), " M", (m_neg ? "-" : "+"),
                                  dig(m_h), dig(m_t), dig(m_o)};
                    else
                        line2 <= {"S", dig(s_h), dig(s_t), dig(s_o), " M", (m_neg ? "-" : "+"),
                                  dig(m_h), dig(m_t), dig(m_o), " ", dig(f_t), dig(f_o), "FPS"};
                    o_state  <= c_state;
                    o_score  <= c_score;
                    o_thr    <= c_thr;
                    text_tog <= ~text_tog;
                    guard    <= 0;
                    st <= T_GUARD;
                end

                T_GUARD: begin                 // keep everything still for the overlay
                    guard <= guard + 1'b1;
                    if (guard == 8'd255) st <= T_IDLE;
                end

                default: st <= T_IDLE;
            endcase
        end
    end
endmodule
