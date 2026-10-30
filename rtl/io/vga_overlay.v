`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// vga_overlay.v  -  result display drawn over the live camera picture.
// Clock: clk_vga (25 MHz). Layout on the 640x480 screen:
//
//   * 6-pixel border in the decision colour
//       green = ZEBRA CROSSING, yellow = NOT SURE, red = NO CROSSING, grey = waiting
//   * top right: the 80x60 image the network actually saw, x2 (160x120)
//   * bottom banner: line 1 in large letters (decision colour), a score bar
//     (0..960 -> 0..480 px) with the threshold (white) and the not-sure band
//     edges (yellow), and line 2 (score, margin, fps) in white
//
// Pipeline: counters -> regions/addresses (E1) -> font ROM and thumbnail BRAM
// data (E2) -> colour (E3). The colour reaches vga_interface 3 clocks after the
// counter value it was computed from, so it is computed for counter + 3.
// sw_off hides the overlay (camera picture only).
//------------------------------------------------------------------------------

module vga_overlay #(
    parameter signed [15:0] BAND_LO = -16'sd31,
    parameter signed [15:0] BAND_HI = 16'sd33,
    parameter FONT_FILE = "font8x16.mem"
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] pixel_x,
    input  wire [11:0] pixel_y,
    input  wire        sw_off_a,

    // from clk_core, stable between text_tog flips
    input  wire        text_tog_a,
    input  wire [127:0] line1_a,
    input  wire [127:0] line2_a,
    input  wire [1:0]  state_a,
    input  wire [15:0] score_a,
    input  wire [15:0] thr_a,

    // thumbnail RAM (1 clock latency)
    output reg  [12:0] th_raddr,
    input  wire [7:0]  th_rdata,

    output reg         ov_en,
    output reg  [11:0] ov_rgb
);
    localparam H_TOTAL = 800, V_TOTAL = 525;
    localparam BORDER = 6;
    localparam TX0 = 470, TY0 = 12;                       // thumbnail 160 x 120
    localparam BX0 = 6,   BY0 = 394, BX1 = 633, BY1 = 473; // banner
    localparam X1 = 16,  Y1 = 398;                        // line 1, 2x scale
    localparam XB = 16,  YB = 436, BAR_W = 480, BAR_H = 10;
    localparam X2 = 16,  Y2 = 452;                        // line 2, 1x scale

    localparam [11:0] C_GREEN = 12'h0F0, C_YELLOW = 12'hFF0, C_RED = 12'hF00,
                      C_GREY = 12'h888, C_WHITE = 12'hFFF, C_BLACK = 12'h000,
                      C_DARK = 12'h333;

    //--------------------------------------------------------------------------
    // Results from clk_core
    //--------------------------------------------------------------------------
    wire text_pulse, sw_off;
    cdc_toggle u_s_text (.clk(clk), .tog(text_tog_a), .pulse(text_pulse));
    cdc_bit    u_s_off  (.clk(clk), .d(sw_off_a), .q(sw_off));

    reg [127:0] line1, line2;
    reg [1:0]   state;
    reg [9:0]   bar_len, thr_x, lo_x, hi_x;
    reg [11:0]  c_state;

    function [9:0] half_clamp;          // max(0, min(v, 959)) / 2
        input signed [16:0] v;
        begin
            if (v < 0)              half_clamp = 10'd0;
            else if (v > 17'sd959)  half_clamp = 10'd479;
            else                    half_clamp = v[10:1];
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            line1 <= "WAITING CAMERA  "; line2 <= "                ";
            state <= 2'd3; bar_len <= 0; thr_x <= 0; lo_x <= 0; hi_x <= 0;
        end else if (text_pulse) begin
            line1   <= line1_a;
            line2   <= line2_a;
            state   <= state_a;
            bar_len <= half_clamp({1'b0, score_a});
            thr_x   <= half_clamp($signed({thr_a[15], thr_a}));
            lo_x    <= half_clamp($signed({thr_a[15], thr_a}) + BAND_LO);
            hi_x    <= half_clamp($signed({thr_a[15], thr_a}) + BAND_HI);
        end
    end

    always @(*) begin
        case (state)
            2'd2:    c_state = C_GREEN;
            2'd1:    c_state = C_YELLOW;
            2'd0:    c_state = C_RED;
            default: c_state = C_GREY;
        endcase
    end

    //--------------------------------------------------------------------------
    // Screen position this pipeline computes: counter + 3
    //--------------------------------------------------------------------------
    wire [11:0] xa = pixel_x + 12'd3;
    wire        wrap = (xa >= H_TOTAL);
    wire [11:0] sx = wrap ? xa - H_TOTAL : xa;
    wire [11:0] sy = wrap ? ((pixel_y == V_TOTAL - 1) ? 12'd0 : pixel_y + 1'b1) : pixel_y;

    //--------------------------------------------------------------------------
    // E1: regions, character codes, addresses
    //--------------------------------------------------------------------------
    wire on_screen = (sx < 640) && (sy < 480);
    wire in_thumb  = (sx >= TX0) && (sx < TX0 + 160) && (sy >= TY0) && (sy < TY0 + 120);
    wire in_tframe = (sx >= TX0 - 2) && (sx < TX0 + 162) && (sy >= TY0 - 2) && (sy < TY0 + 122);
    wire in_border = (sx < BORDER) || (sx >= 640 - BORDER) || (sy < BORDER) || (sy >= 480 - BORDER);
    wire in_banner = (sx >= BX0) && (sx <= BX1) && (sy >= BY0) && (sy <= BY1);
    wire in_t1     = (sx >= X1) && (sx < X1 + 256) && (sy >= Y1) && (sy < Y1 + 32);
    wire in_t2     = (sx >= X2) && (sx < X2 + 128) && (sy >= Y2) && (sy < Y2 + 16);
    wire in_bar    = (sx >= XB) && (sx < XB + BAR_W) && (sy >= YB) && (sy < YB + BAR_H);

    wire [11:0] dx1 = sx - X1, dy1 = sy - Y1;
    wire [11:0] dx2 = sx - X2, dy2 = sy - Y2;
    wire [3:0]  ci1 = dx1[7:4];                 // character index, 16 px per char
    wire [3:0]  ci2 = dx2[6:3];                 // 8 px per char
    wire [7:0]  ch1 = line1[8*(15-ci1) +: 8];
    wire [7:0]  ch2 = line2[8*(15-ci2) +: 8];

    wire [11:0] tdx = sx - TX0, tdy = sy - TY0;
    wire [12:0] th_addr_n = tdy[7:1] * 7'd80 + tdx[7:1];

    reg        e1_on, e1_thumb, e1_tframe, e1_border, e1_banner, e1_t1, e1_t2, e1_bar;
    reg [2:0]  e1_col;
    reg [9:0]  e1_bx;
    reg [10:0] font_addr;

    always @(posedge clk) begin
        e1_on     <= on_screen && !sw_off;
        e1_thumb  <= in_thumb;
        e1_tframe <= in_tframe;
        e1_border <= in_border;
        e1_banner <= in_banner;
        e1_t1     <= in_t1;
        e1_t2     <= in_t2;
        e1_bar    <= in_bar;
        e1_col    <= in_t1 ? dx1[3:1] : dx2[2:0];
        e1_bx     <= sx - XB;
        font_addr <= in_t1 ? {ch1[6:0], dy1[4:1]} : {ch2[6:0], dy2[3:0]};
        th_raddr  <= th_addr_n;
    end

    //--------------------------------------------------------------------------
    // E2: font row and thumbnail pixel arrive
    //--------------------------------------------------------------------------
    reg [7:0] font_rom [0:2047];
    initial $readmemh(FONT_FILE, font_rom);
    reg [7:0] font_q;

    reg        e2_on, e2_thumb, e2_tframe, e2_border, e2_banner, e2_t1, e2_t2, e2_bar;
    reg [2:0]  e2_col;
    reg [9:0]  e2_bx;

    always @(posedge clk) begin
        font_q    <= font_rom[font_addr];
        e2_on     <= e1_on;
        e2_thumb  <= e1_thumb;
        e2_tframe <= e1_tframe;
        e2_border <= e1_border;
        e2_banner <= e1_banner;
        e2_t1     <= e1_t1;
        e2_t2     <= e1_t2;
        e2_bar    <= e1_bar;
        e2_col    <= e1_col;
        e2_bx     <= e1_bx;
    end

    //--------------------------------------------------------------------------
    // E3: colour
    //--------------------------------------------------------------------------
    wire glyph = font_q[3'd7 - e2_col];

    always @(posedge clk) begin
        if (!rst_n) begin
            ov_en <= 0; ov_rgb <= 0;
        end else begin
            ov_en  <= 0;
            ov_rgb <= C_BLACK;
            if (e2_on) begin
                if (e2_thumb) begin
                    ov_en  <= 1;
                    ov_rgb <= {th_rdata[7:4], th_rdata[7:4], th_rdata[7:4]};
                end else if (e2_tframe) begin
                    ov_en  <= 1;
                    ov_rgb <= C_WHITE;
                end else if (e2_border) begin
                    ov_en  <= 1;
                    ov_rgb <= c_state;
                end else if (e2_banner) begin
                    ov_en <= 1;
                    if (e2_t1 && glyph)
                        ov_rgb <= c_state;
                    else if (e2_t2 && glyph)
                        ov_rgb <= C_WHITE;
                    else if (e2_bar) begin
                        if (e2_bx == thr_x)                      ov_rgb <= C_WHITE;
                        else if (e2_bx == lo_x || e2_bx == hi_x) ov_rgb <= C_YELLOW;
                        else if (e2_bx < bar_len)                ov_rgb <= c_state;
                        else                                     ov_rgb <= C_DARK;
                    end
                end
            end
        end
    end
endmodule
