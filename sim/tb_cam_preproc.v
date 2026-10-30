`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// tb_cam_preproc.v  -  OV7670 model -> cam_preproc; every committed 80x60
// frame is written to got<k>.hex for python/check_preproc.py to compare with
// cam_golden.camera_input(). Runs FRAMES frames, then stops.
//------------------------------------------------------------------------------

module tb_cam_preproc;
    parameter FRAMES        = 3;
    parameter NFRAMES       = 2;
    parameter PCLK_IN_BLANK = 0;
    parameter BAD_LINE      = -1;

    reg clk = 0;
    always #3.75 clk = ~clk;               // 133.33 MHz
    reg rst_n = 0;

    wire pclk, href, vsync;
    wire [7:0] data;
    wire [31:0] sent;

    ov7670_model #(.NFRAMES(NFRAMES), .PCLK_IN_BLANK(PCLK_IN_BLANK), .BAD_LINE(BAD_LINE)) cam (
        .run(rst_n), .pclk(pclk), .href(href), .vsync(vsync), .data(data), .frames_sent(sent));

    wire        fb_we;
    wire [13:0] fb_addr;
    wire [7:0]  fb_data;
    wire        frame_bank, frame_tog;
    wire [15:0] frame_cnt, bad_frames;
    wire [10:0] last_line_len;
    wire [9:0]  last_lines;

    cam_preproc dut (
        .clk(clk), .rst_n(rst_n),
        .cmos_pclk(pclk), .cmos_href(href), .cmos_vsync(vsync), .cmos_db(data),
        .fb_we(fb_we), .fb_addr(fb_addr), .fb_data(fb_data),
        .frame_bank(frame_bank), .frame_tog(frame_tog), .frame_cnt(frame_cnt),
        .bad_frames(bad_frames), .last_line_len(last_line_len), .last_lines(last_lines));

    reg [7:0] fb [0:9599];
    always @(posedge clk) if (fb_we) fb[fb_addr] <= fb_data;

    reg tog_d = 0;
    integer k = 0, i, fd;
    reg [8*16-1:0] fname;
    always @(posedge clk) begin
        tog_d <= frame_tog;
        if (rst_n && frame_tog != tog_d) begin
            #1;
            $sformat(fname, "got%0d.hex", k);
            fd = $fopen(fname, "w");
            for (i = 0; i < 4800; i = i + 1)
                $fdisplay(fd, "%02x", fb[(frame_bank ? 4800 : 0) + i]);
            $fclose(fd);
            $display(" commit %0d: bank %0d frame_cnt %0d bad %0d line_len %0d lines %0d  (camera frames sent %0d)",
                     k, frame_bank, frame_cnt, bad_frames, last_line_len, last_lines, sent);
            k = k + 1;
        end
    end

    initial begin
        #200 rst_n = 1;
        wait (sent == FRAMES);
        #2000;
        $display(" DONE: %0d frames sent, %0d committed, %0d rejected", sent, frame_cnt, bad_frames);
        $finish;
    end
endmodule
