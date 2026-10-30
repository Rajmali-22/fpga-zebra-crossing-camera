`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// top.v  -  Zebra-crossing camera on the EDGE Artix-7 (XC7A35T-1FTG256C)
//
//   OV7670 --+--> camera_interface -> SDRAM -> VGA (live picture)   [proven]
//            |                         `-> frame_capture -> UART    [proven]
//            `--> vision: 80x60 preprocessing -> v3 BCNN -> decision
//                           -> VGA overlay, 16x2 LCD, buzzer, LEDs, UART
//
// The detection path reads the camera pins itself; it does not depend on the
// SDRAM, so a VGA problem can never stop the detector.
//
// Instance names m0..m7 are those of the hardware-proven camera build, so its
// SDRAM register placement (vivado/sdram_loc.xdc) applies unchanged.
//
// Switches  sw[3:0]  camera brightness / contrast (unchanged, keep UP)
//           sw[4]    plain decision (margin >= 0, no "not sure")
//           sw[5]    no averaging over frames
//           sw[6]    buzzer mute
//           sw[7]    hide the VGA overlay
//           sw[8]    raw camera picture to the network (no auto-contrast)
//           M6       reset (UP = run)
//
// LEDs      0  ZEBRA CROSSING - YES          (the answer, solid)
//           1  NOT SURE                       2  NO CROSSING
//           3  camera configured              4  camera frames arriving (blinks)
//           5  BCNN computing                 6  UART busy
//           7  heartbeat (design alive)
//           8..15  confidence meter: lights fill up from LED 8 as the network
//                  becomes surer there is a crossing (averaged margin -64 .. +64;
//                  6 or more lit = CROSSING, 2 or fewer = NO CROSSING)
// Button    centre   full-resolution photo to the PC (unchanged)
//------------------------------------------------------------------------------

module top #(
    parameter CORE_DIV = 12,                        // 800 MHz / 12 = 66.7 MHz BCNN clock: 34 ms per
                                                    // inference < 37.5 ms per camera frame
    parameter AVG_LOG2 = 2,                         // average over 4 frames
    parameter signed [15:0] BAND_LO = -16'sd31,     // mem/demo.json
    parameter signed [15:0] BAND_HI = 16'sd33,
    parameter PROVEN_SDRAM = 0,                     // 1: build with vivado/sdram_loc.xdc
    parameter STRETCH_PHOTO = 0                     // 1: PC photos are auto-contrasted too
                                                    //    (for weights trained that way, v3cs)
)(
    input  wire        clk,             // 50 MHz, N11
    input  wire        rst_n,           // M6 switch, UP = run
    input  wire [3:0]  key,             // sw[3:0]
    input  wire        sw_plain,        // sw[4]
    input  wire        sw_noavg,        // sw[5]
    input  wire        sw_mute,         // sw[6]
    input  wire        sw_ovl_off,      // sw[7]
    input  wire        sw_raw,          // sw[8]
    input  wire        btn_capture,     // centre push-button

    // camera
    input  wire        cmos_pclk, cmos_href, cmos_vsync,
    input  wire [7:0]  cmos_db,
    inout  wire        cmos_sda, cmos_scl,
    output wire        cmos_rst_n, cmos_pwdn, cmos_xclk,

    // SDRAM
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n,
    output wire [12:0] sdram_addr,
    output wire [1:0]  sdram_ba,
    output wire [1:0]  sdram_dqm,
    inout  wire [15:0] sdram_dq,

    // VGA
    output wire [3:0]  vga_out_r, vga_out_g, vga_out_b,
    output wire        vga_out_vs, vga_out_hs,

    // USB UART
    input  wire        uart_rxd,
    output wire        uart_txd,

    // 16x2 LCD, buzzer, LEDs
    output wire [7:0]  lcd_data,
    output wire        lcd_rs,
    output wire        lcd_e,
    output wire        buzzer_out,
    output wire [15:0] led
);
    localparam SYS_HZ  = 133_333_333;
    localparam CORE_HZ = 800_000_000 / CORE_DIV;
    localparam BAUD    = 5_333_333;                  // 133.33 MHz / 25, FT2232H 12 MHz / 2.25
    localparam [7:0] BUILD_FLAGS = {5'd0, (STRETCH_PHOTO != 0), (CORE_DIV != 16), (PROVEN_SDRAM != 0)};

    //--------------------------------------------------------------------------
    // Clocks and resets
    //--------------------------------------------------------------------------
    wire clk_xclk, clk_sys, clk_vga, clk_core, locked;
    wire rst_n_sys, rst_n_vga, rst_n_core;

    clk_rst #(.CORE_DIV(CORE_DIV)) u_clk (
        .clk_in(clk), .rst_n_in(rst_n),
        .clk_xclk(clk_xclk), .clk_sys(clk_sys), .clk_vga(clk_vga), .clk_core(clk_core),
        .locked(locked), .rst_n_sys(rst_n_sys), .rst_n_vga(rst_n_vga), .rst_n_core(rst_n_core));

    // forwarded clocks: camera XCLK, and SDRAM clock inverted (as in the proven
    // build: the SDRAM samples on the falling edge of clk_sys)
    ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_xclk_oddr (
        .Q(cmos_xclk), .C(clk_xclk), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

    ODDR #(.DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr2_primitive (
        .Q(sdram_clk), .C(clk_sys), .CE(1'b1), .D1(1'b0), .D2(1'b1), .R(1'b0), .S(1'b0));

    //--------------------------------------------------------------------------
    // Proven camera -> SDRAM -> VGA path, plus photo capture
    //--------------------------------------------------------------------------
    wire        f2s_data_valid, empty_fifo, rd_en;
    wire [9:0]  data_count_r;
    wire [15:0] dout, din;
    wire [3:0]  cam_led;

    wire        cap_freeze, cap_pause, cam_fifo_flush, frame_sync;
    wire        cap_rd_req, cap_rd_ack, cap_data_valid, cap_busy;
    wire [14:0] cap_rd_addr;
    wire [15:0] cap_data;

    camera_interface m0 (
        .clk(clk), .clk_100(clk_sys), .rst_n(rst_n_sys), .key(key),
        .rd_en(f2s_data_valid), .data_count_r(data_count_r), .dout(dout),
        .cap_pause(cap_pause), .fifo_flush(cam_fifo_flush),
        .cmos_pclk(cmos_pclk), .cmos_href(cmos_href), .cmos_vsync(cmos_vsync), .cmos_db(cmos_db),
        .cmos_sda(cmos_sda), .cmos_scl(cmos_scl), .cmos_rst_n(cmos_rst_n), .cmos_pwdn(cmos_pwdn),
        .led(cam_led));

    sdram_interface m1 (
        .clk(clk_sys), .rst_n(rst_n_sys),
        .clk_vga(clk_vga), .rd_en(rd_en), .data_count_r(data_count_r),
        .f2s_data(dout), .f2s_data_valid(f2s_data_valid), .empty_fifo(empty_fifo), .dout(din),
        .freeze(cap_freeze), .cap_rd_req(cap_rd_req), .cap_rd_addr(cap_rd_addr),
        .cap_rd_ack(cap_rd_ack), .cap_data(cap_data), .cap_data_valid(cap_data_valid),
        .frame_sync(frame_sync),
        .sdram_clk(), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n), .sdram_addr(sdram_addr),
        .sdram_ba(sdram_ba), .sdram_dqm(sdram_dqm), .sdram_dq(sdram_dq));

    wire        ov_en;
    wire [11:0] ov_rgb, pix_x, pix_y;

    vga_interface m2 (
        .clk_vga(clk_vga), .rst_n(rst_n_vga),
        .empty_fifo(empty_fifo), .din(din), .rd_en(rd_en),
        .ov_en(ov_en), .ov_rgb(ov_rgb), .pix_x(pix_x), .pix_y(pix_y),
        .vga_out_r(vga_out_r), .vga_out_g(vga_out_g), .vga_out_b(vga_out_b),
        .vga_out_vs(vga_out_vs), .vga_out_hs(vga_out_hs));

    //--------------------------------------------------------------------------
    // UART: shared by frame_capture ('c', 'd', button) and the vision link
    //--------------------------------------------------------------------------
    wire [7:0] rx_data, tx_data, fc_tx_data, vl_tx_data;
    wire       rx_valid, tx_busy, fc_tx_wr, vl_tx_wr, link_busy, btn_tick;

    uart_rx #(.CLK_FREQ(SYS_HZ), .BAUD(BAUD)) m5 (
        .clk(clk_sys), .rst_n(rst_n_sys), .rx(uart_rxd), .dout(rx_data), .valid(rx_valid));

    assign tx_data = link_busy ? vl_tx_data : fc_tx_data;
    uart_tx #(.CLK_FREQ(SYS_HZ), .BAUD(BAUD)) m6 (
        .clk(clk_sys), .rst_n(rst_n_sys), .din(tx_data), .wr_en(fc_tx_wr | vl_tx_wr),
        .tx(uart_txd), .busy(tx_busy));

    debounce_explicit m7 (
        .clk(clk_sys), .rst_n(rst_n_sys), .sw(btn_capture), .db_level(), .db_tick(btn_tick));

    frame_capture #(.H_ACTIVE(640), .V_ACTIVE(480), .WORDS_PER_BURST(512), .BURSTS_PER_FRAME(600)) m4 (
        .clk(clk_sys), .rst_n(rst_n_sys),
        .btn_tick(btn_tick & ~link_busy),
        .rx_data(rx_data), .rx_valid(rx_valid & ~link_busy),
        .tx_data(fc_tx_data), .tx_wr(fc_tx_wr), .tx_busy(tx_busy),
        .freeze(cap_freeze), .cam_pause(cap_pause), .cam_fifo_flush(cam_fifo_flush),
        .frame_sync(frame_sync), .cap_rd_req(cap_rd_req), .cap_rd_addr(cap_rd_addr),
        .cap_rd_ack(cap_rd_ack), .cap_data(cap_data), .cap_data_valid(cap_data_valid),
        .cap_busy(cap_busy));

    //--------------------------------------------------------------------------
    // Detection path
    //--------------------------------------------------------------------------
    wire        res_tog, res_src, res_paused, res_stretched, core_busy, frame_tog;
    wire [1:0]  res_state;
    wire [15:0] res_score, frame_cnt;
    wire signed [15:0] res_thr, res_margin, res_avg;
    wire [7:0]  res_fps;
    wire [12:0] vga_th_raddr;
    wire [7:0]  vga_th_rdata;

    vision #(
        .SYS_HZ(SYS_HZ), .CORE_HZ(CORE_HZ), .AVG_LOG2(AVG_LOG2),
        .BAND_LO(BAND_LO), .BAND_HI(BAND_HI), .BUILD_FLAGS(BUILD_FLAGS),
        .STRETCH_PHOTO(STRETCH_PHOTO)
    ) u_vision (
        .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .clk_core(clk_core), .rst_n_core(rst_n_core),
        .clk_vga(clk_vga),
        .cmos_pclk(cmos_pclk), .cmos_href(cmos_href), .cmos_vsync(cmos_vsync), .cmos_db(cmos_db),
        .rx_data(rx_data), .rx_valid(rx_valid), .tx_busy(tx_busy),
        .tx_data(vl_tx_data), .tx_wr(vl_tx_wr), .cap_busy(cap_busy), .link_busy(link_busy),
        .sw_plain(sw_plain), .sw_noavg(sw_noavg), .sw_raw(sw_raw), .cam_led(cam_led),
        .vga_th_raddr(vga_th_raddr), .vga_th_rdata(vga_th_rdata),
        .res_tog(res_tog), .res_state(res_state), .res_src(res_src),
        .res_score(res_score), .res_thr(res_thr), .res_margin(res_margin), .res_avg(res_avg),
        .res_fps(res_fps), .res_paused(res_paused), .res_stretched(res_stretched),
        .core_busy(core_busy),
        .frame_tog(frame_tog), .frame_cnt(frame_cnt));

    //--------------------------------------------------------------------------
    // Outputs: text, LCD, buzzer (clk_core); overlay (clk_vga)
    //--------------------------------------------------------------------------
    wire [127:0] line1, line2;
    wire         text_tog;
    wire [1:0]   ovl_state;
    wire [15:0]  ovl_score, ovl_thr;

    status_text #(.CLK_HZ(CORE_HZ)) u_text (
        .clk(clk_core), .rst_n(rst_n_core),
        .res_tog(res_tog), .res_state(res_state), .res_src(res_src), .res_paused(res_paused),
        .res_score(res_score), .res_margin(res_margin), .res_fps(res_fps), .res_thr(res_thr),
        .line1(line1), .line2(line2), .o_state(ovl_state), .o_score(ovl_score), .o_thr(ovl_thr),
        .text_tog(text_tog));

    lcd_hd44780 #(.CLK_HZ(CORE_HZ)) u_lcd (
        .clk(clk_core), .rst_n(rst_n_core), .line1(line1), .line2(line2),
        .lcd_data(lcd_data), .lcd_rs(lcd_rs), .lcd_e(lcd_e));

    wire mute;
    cdc_bit u_s_mute (.clk(clk_core), .d(sw_mute), .q(mute));
    buzzer #(.CLK_HZ(CORE_HZ)) u_buzz (
        .clk(clk_core), .rst_n(rst_n_core),
        .enable(res_state == 2'd2 && !mute), .out(buzzer_out));

    vga_overlay #(.BAND_LO(BAND_LO), .BAND_HI(BAND_HI)) u_ovl (
        .clk(clk_vga), .rst_n(rst_n_vga), .pixel_x(pix_x), .pixel_y(pix_y), .sw_off_a(sw_ovl_off),
        .text_tog_a(text_tog), .line1_a(line1), .line2_a(line2), .state_a(ovl_state),
        .score_a(ovl_score), .thr_a(ovl_thr),
        .th_raddr(vga_th_raddr), .th_rdata(vga_th_rdata),
        .ov_en(ov_en), .ov_rgb(ov_rgb));

    //--------------------------------------------------------------------------
    // LEDs (see the header). The confidence meter shows the averaged margin the
    // decision is taken on: n = clamp((avg + 64) / 16, 0, 8) LEDs lit.
    //--------------------------------------------------------------------------
    // camera_interface shows 0110 when its SCCB setup is done; a later
    // brightness/contrast change (sw0-3) or a FIFO overflow turns it into 1001,
    // so remember the first 0110
    reg cam_cfg = 1'b0;
    always @(posedge clk_sys) begin
        if (!rst_n_sys)                cam_cfg <= 1'b0;
        else if (cam_led == 4'b0110)   cam_cfg <= 1'b1;
    end

    reg [25:0] hb = 26'd0;
    reg [7:0]  meter = 8'd0;
    wire signed [16:0] mlev = $signed({res_avg[15], res_avg}) + 17'sd64;
    always @(posedge clk_core) begin
        hb <= hb + 1'b1;
        if (res_state == 2'd3)        meter <= 8'h00;          // no camera result yet
        else if (mlev < 17'sd16)      meter <= 8'h00;
        else if (mlev >= 17'sd128)    meter <= 8'hFF;
        else                          meter <= 8'hFF >> (4'd8 - mlev[6:4]);
    end

    assign led[0]    = (res_state == 2'd2);       // ZEBRA CROSSING - YES
    assign led[1]    = (res_state == 2'd1);
    assign led[2]    = (res_state == 2'd0);
    assign led[3]    = cam_cfg;                  // camera setup finished since reset
    assign led[4]    = frame_cnt[2];
    assign led[5]    = core_busy;
    assign led[6]    = link_busy | cap_busy;
    assign led[7]    = hb[25];
    assign led[15:8] = meter;

endmodule
