`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// tb_display.v  -  VGA overlay + status text + LCD, with fake results.
//
// * vga_interface (camera picture = a colour test pattern from a fake FIFO)
//   + vga_overlay + thumbnail RAM loaded from thumb.hex; one full frame after
//   the result arrives is written to vga.hex (640x480 RGB444) -> PNG.
// * status_text -> lcd_hd44780 -> a small HD44780 model that rebuilds the two
//   display lines from the E/RS/data bus; they are printed at the end.
// Result: STATE / SCORE / THR / MARGIN / SRC parameters.
//------------------------------------------------------------------------------

module tb_display;
    parameter STATE  = 2;
    parameter SCORE  = 561;
    parameter THR    = 477;
    parameter MARGIN = 84;
    parameter SRC    = 0;
    parameter FPS    = 13;
    parameter CAMFILE = 0;

    reg clk_vga = 0, clk_core = 0;
    always #20 clk_vga = ~clk_vga;              // 25 MHz
    always #250 clk_core = ~clk_core;           // 2 MHz core clock keeps the LCD sim short
    reg rst_n = 0;

    // fake result bundle (clk_core)
    reg        res_tog = 0;
    reg [1:0]  res_state = 2'd3;
    reg [15:0] res_score = 0;
    reg signed [15:0] res_margin = 0, res_thr = 0;
    reg [7:0]  res_fps = 0;

    wire [127:0] line1, line2;
    wire [1:0]   o_state;
    wire [15:0]  o_score, o_thr;
    wire         text_tog;

    status_text #(.CLK_HZ(2_000_000)) u_text (
        .clk(clk_core), .rst_n(rst_n), .res_tog(res_tog), .res_state(res_state),
        .res_src(SRC[0]), .res_paused(1'b0), .res_score(res_score), .res_margin(res_margin),
        .res_fps(res_fps), .res_thr(res_thr), .line1(line1), .line2(line2),
        .o_state(o_state), .o_score(o_score), .o_thr(o_thr), .text_tog(text_tog));

    // LCD + model
    wire [7:0] lcd_data;
    wire lcd_rs, lcd_e;
    lcd_hd44780 #(.CLK_HZ(2_000_000)) u_lcd (
        .clk(clk_core), .rst_n(rst_n), .line1(line1), .line2(line2),
        .lcd_data(lcd_data), .lcd_rs(lcd_rs), .lcd_e(lcd_e));

    hd44780_model u_model (.e(lcd_e), .rs(lcd_rs), .d(lcd_data));

    // VGA
    wire [11:0] pix_x, pix_y, ov_rgb;
    wire        ov_en, rd_en, hs, vs;
    wire [3:0]  r, g, b;
    // camera picture: a colour test pattern, or (CAMFILE = 1) a 640x480 RGB565
    // frame from cam.hex, delivered in the order vga_interface reads it
    reg  [15:0] fifo_px = 0;
    reg  [15:0] cam [0:307199];
    integer     cidx = 0;
    initial if (CAMFILE) $readmemh("cam.hex", cam);
    always @(posedge clk_vga) if (rd_en) begin
        fifo_px <= fifo_px + 16'h0821;
        cidx    <= (cidx == 307199) ? 0 : cidx + 1;
    end
    wire [15:0] cam_px = CAMFILE ? cam[cidx] : fifo_px;

    vga_interface u_vga (
        .clk_vga(clk_vga), .rst_n(rst_n), .empty_fifo(1'b0), .din(cam_px), .rd_en(rd_en),
        .ov_en(ov_en), .ov_rgb(ov_rgb), .pix_x(pix_x), .pix_y(pix_y),
        .vga_out_r(r), .vga_out_g(g), .vga_out_b(b), .vga_out_vs(vs), .vga_out_hs(hs));

    wire [12:0] th_raddr;
    wire [7:0]  th_rdata;
    reg  [7:0]  thumb [0:8191];
    reg  [7:0]  th_q = 0;
    initial $readmemh("thumb.hex", thumb);
    always @(posedge clk_vga) th_q <= thumb[th_raddr];
    assign th_rdata = th_q;

    vga_overlay u_ovl (
        .clk(clk_vga), .rst_n(rst_n), .pixel_x(pix_x), .pixel_y(pix_y), .sw_off_a(1'b0),
        .text_tog_a(text_tog), .line1_a(line1), .line2_a(line2), .state_a(o_state),
        .score_a(o_score), .thr_a(o_thr), .th_raddr(th_raddr), .th_rdata(th_rdata),
        .ov_en(ov_en), .ov_rgb(ov_rgb));

    // capture one frame: one line "x y rgb" per visible counter position
    // (vga_core never shows counter (0,0): line 524 lasts one clock and line 0
    // starts at x = 1 - a property of the proven VGA core, harmless on monitors)
    integer fd;
    reg     capture = 0;
    always @(posedge clk_vga) begin
        if (capture && pix_x < 640 && pix_y < 480)
            $fdisplay(fd, "%0d %0d %01x%01x%01x", pix_x, pix_y, r, g, b);
    end

    initial begin
        #1000 rst_n = 1;
        #1000;
        @(posedge clk_core);
        res_state <= STATE; res_score <= SCORE; res_thr <= THR; res_margin <= MARGIN; res_fps <= FPS;
        res_tog <= 1;
        #200_000;                                   // text built and crossed over
        // one full frame, from the first line after the next vertical sync
        @(negedge vs);
        @(posedge vs);
        $display(" [%0t] frame start", $time);
        fd = $fopen("vga.hex", "w");
        capture = 1;
        @(negedge vs);
        capture = 0;
        $fclose(fd);
        // LCD: init (~60 ms) + one refresh cycle
        #160_000_000;
        u_model.show;
        $finish;
    end
endmodule
