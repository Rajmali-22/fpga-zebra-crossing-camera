`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// vision.v  -  the whole detection path, independent of SDRAM and VGA:
//
//   camera pins -> cam_preproc -> frame buffer (banks 0/1 camera, 2 upload)
//               -> bcnn_engine (clk_core) -> result bundle
//                                         -> thumbnail RAMs (UART, VGA)
//   UART bytes <-> uart_link (snapshots, photo upload, status)
//
// Clock domains: clk_sys (camera, UART), clk_core (BCNN), clk_vga (thumbnail
// read port only). All crossings are BRAMs with one port per clock, or the
// toggle / level handshakes of cdc.v.
//------------------------------------------------------------------------------

module vision #(
    parameter SYS_HZ      = 133_333_333,
    parameter CORE_HZ     = 50_000_000,
    parameter AVG_LOG2    = 2,
    parameter signed [15:0] BAND_LO = -16'sd31,
    parameter signed [15:0] BAND_HI = 16'sd33,
    parameter [7:0] BUILD_FLAGS = 8'h00,
    parameter STRETCH_PHOTO = 0,
    parameter WEIGHT_FILE = "bcnn_weights.mem",
    parameter THRESH_FILE = "bcnn_thresh.mem"
)(
    input  wire        clk_sys,
    input  wire        rst_n_sys,
    input  wire        clk_core,
    input  wire        rst_n_core,
    input  wire        clk_vga,

    input  wire        cmos_pclk,
    input  wire        cmos_href,
    input  wire        cmos_vsync,
    input  wire [7:0]  cmos_db,

    // UART (clk_sys)
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        tx_busy,
    output wire [7:0]  tx_data,
    output wire        tx_wr,
    input  wire        cap_busy,
    output wire        link_busy,

    input  wire        sw_plain,
    input  wire        sw_noavg,
    input  wire        sw_raw,          // 1: no auto-contrast on camera frames
    input  wire [3:0]  cam_led,

    // thumbnail for the VGA overlay (clk_vga, 1 clock latency)
    input  wire [12:0] vga_th_raddr,
    output wire [7:0]  vga_th_rdata,

    // results (clk_core)
    output wire        res_tog,
    output wire [1:0]  res_state,
    output wire        res_src,
    output wire [15:0] res_score,
    output wire signed [15:0] res_thr,
    output wire signed [15:0] res_margin,
    output wire signed [15:0] res_avg,
    output wire [7:0]  res_fps,
    output wire        res_paused,
    output wire        res_stretched,
    output wire        core_busy,

    // camera activity (clk_sys)
    output wire        frame_tog,
    output wire [15:0] frame_cnt
);
    localparam BANK = 4800;

    //--------------------------------------------------------------------------
    // Camera -> 80x60
    //--------------------------------------------------------------------------
    wire        pp_we;
    wire [13:0] pp_addr;
    wire [7:0]  pp_data;
    wire        frame_bank;
    wire [15:0] bad_frames;
    wire [10:0] last_line_len;
    wire [9:0]  last_lines;

    cam_preproc #(.BANK(BANK)) u_pre (
        .clk(clk_sys), .rst_n(rst_n_sys),
        .cmos_pclk(cmos_pclk), .cmos_href(cmos_href), .cmos_vsync(cmos_vsync), .cmos_db(cmos_db),
        .fb_we(pp_we), .fb_addr(pp_addr), .fb_data(pp_data),
        .frame_bank(frame_bank), .frame_tog(frame_tog), .frame_cnt(frame_cnt),
        .bad_frames(bad_frames), .last_line_len(last_line_len), .last_lines(last_lines));

    //--------------------------------------------------------------------------
    // Frame buffer: camera writes win; an uploaded byte waits one clock if it
    // collides (uploaded bytes are >= 250 clocks apart).
    //--------------------------------------------------------------------------
    wire        inj_we;
    wire [13:0] inj_addr;
    wire [7:0]  inj_data;
    reg         ib_valid;
    reg  [13:0] ib_addr;
    reg  [7:0]  ib_data;

    always @(posedge clk_sys) begin
        if (!rst_n_sys) begin
            ib_valid <= 0; ib_addr <= 0; ib_data <= 0;
        end else begin
            if (!pp_we) ib_valid <= 0;
            if (inj_we) begin
                ib_valid <= 1; ib_addr <= inj_addr; ib_data <= inj_data;
            end
        end
    end

    wire        fb_we    = pp_we | ib_valid;
    wire [13:0] fb_waddr = pp_we ? pp_addr : ib_addr;
    wire [7:0]  fb_wdata = pp_we ? pp_data : ib_data;

    wire [13:0] fb_raddr;
    wire [7:0]  fb_rdata;

    bram_sdp #(.AW(14), .DW(8)) u_fbuf (
        .wclk(clk_sys), .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata),
        .rclk(clk_core), .raddr(fb_raddr), .rdata(fb_rdata));

    //--------------------------------------------------------------------------
    // BCNN engine
    //--------------------------------------------------------------------------
    wire        th_we;
    wire [12:0] th_addr;
    wire [7:0]  th_data;
    wire        inject_tog, snap_req, cam_pause;
    wire        snap_ack, inject_done_tog, inj_detect;
    wire [15:0] inj_score;
    wire signed [15:0] inj_thr;
    wire [15:0] res_frame, res_infer, res_missed;
    wire [7:0]  res_lo, res_hi;

    bcnn_engine #(
        .CLK_HZ(CORE_HZ), .BANK(BANK), .AVG_LOG2(AVG_LOG2),
        .BAND_LO(BAND_LO), .BAND_HI(BAND_HI), .STRETCH_PHOTO(STRETCH_PHOTO),
        .WEIGHT_FILE(WEIGHT_FILE), .THRESH_FILE(THRESH_FILE)
    ) u_engine (
        .clk(clk_core), .rst_n(rst_n_core),
        .frame_tog_a(frame_tog), .frame_bank_a(frame_bank), .frame_cnt_a(frame_cnt),
        .inject_tog_a(inject_tog), .snap_req_a(snap_req), .cam_pause_a(cam_pause),
        .sw_plain_a(sw_plain), .sw_noavg_a(sw_noavg), .sw_raw_a(sw_raw),
        .fb_raddr(fb_raddr), .fb_rdata(fb_rdata),
        .th_we(th_we), .th_addr(th_addr), .th_data(th_data),
        .snap_ack(snap_ack), .inject_done_tog(inject_done_tog),
        .inj_detect(inj_detect), .inj_score(inj_score), .inj_thr(inj_thr),
        .res_tog(res_tog), .res_state(res_state), .res_src(res_src),
        .res_score(res_score), .res_thr(res_thr), .res_margin(res_margin), .res_avg(res_avg),
        .res_frame(res_frame), .res_infer(res_infer), .res_fps(res_fps),
        .res_missed(res_missed), .res_paused(res_paused),
        .res_stretched(res_stretched), .res_lo(res_lo), .res_hi(res_hi),
        .core_busy(core_busy));

    //--------------------------------------------------------------------------
    // Thumbnails of the image the network saw
    //--------------------------------------------------------------------------
    wire [12:0] th_raddr;
    wire [7:0]  th_rdata;

    bram_sdp #(.AW(13), .DW(8)) u_th_uart (
        .wclk(clk_core), .we(th_we), .waddr(th_addr), .wdata(th_data),
        .rclk(clk_sys), .raddr(th_raddr), .rdata(th_rdata));

    bram_sdp #(.AW(13), .DW(8)) u_th_vga (
        .wclk(clk_core), .we(th_we), .waddr(th_addr), .wdata(th_data),
        .rclk(clk_vga), .raddr(vga_th_raddr), .rdata(vga_th_rdata));

    //--------------------------------------------------------------------------
    // UART commands
    //--------------------------------------------------------------------------
    uart_link #(.CLK_HZ(SYS_HZ), .BANK(BANK), .BUILD_FLAGS(BUILD_FLAGS)) u_link (
        .clk(clk_sys), .rst_n(rst_n_sys),
        .rx_data(rx_data), .rx_valid(rx_valid), .tx_busy(tx_busy),
        .tx_data(tx_data), .tx_wr(tx_wr), .cap_busy(cap_busy), .link_busy(link_busy),
        .inj_we(inj_we), .inj_addr(inj_addr), .inj_data(inj_data), .inject_tog(inject_tog),
        .inject_done_tog_a(inject_done_tog), .inj_detect_a(inj_detect), .inj_score_a(inj_score),
        .snap_req(snap_req), .snap_ack_a(snap_ack), .cam_pause(cam_pause),
        .th_raddr(th_raddr), .th_rdata(th_rdata),
        .res_state_a(res_state), .res_src_a(res_src), .res_paused_a(res_paused),
        .res_score_a(res_score), .res_thr_a(res_thr), .res_margin_a(res_margin),
        .res_avg_a(res_avg), .res_frame_a(res_frame), .res_infer_a(res_infer),
        .res_fps_a(res_fps), .res_missed_a(res_missed),
        .res_stretched_a(res_stretched), .res_lo_a(res_lo), .res_hi_a(res_hi),
        .frame_cnt(frame_cnt), .bad_frames(bad_frames), .last_line_len(last_line_len),
        .last_lines(last_lines), .cam_led(cam_led));

endmodule
