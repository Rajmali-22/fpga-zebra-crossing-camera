`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// tb_top.v  -  the complete FPGA design (top.v) as the board sees it:
// 50 MHz oscillator, reset switch, OV7670 model on the camera pins, a serial
// "PC" on uart_rxd / uart_txd, LEDs observed. The SDRAM pins are left without
// a memory (pulled low): the detection path must not depend on it.
//
// The PC sends 'v', waits for INFER_WAIT results, sends 'g', 's', then a
// photo upload and 'r'; bytes received go to rx.hex (sim/check_top.py).
// The LED vector at each result is printed.
//------------------------------------------------------------------------------

module tb_top;
    parameter INFER_WAIT = 3;
    localparam real BIT_NS = 1.0e9 / 5333333.333;

    reg clk = 0;
    always #10 clk = ~clk;                       // 50 MHz board oscillator
    reg rst_n = 0;

    // camera
    wire pclk, href, vsync;
    wire [7:0] cdata;
    wire [31:0] sent;
    ov7670_model #(.NFRAMES(2), .HBLANK(16)) cam (
        .run(1'b1), .pclk(pclk), .href(href), .vsync(vsync), .data(cdata), .frames_sent(sent));

    tri1 sda, scl;                                // SCCB lines with pull-ups
    tri0 [15:0] sdram_dq;                         // no SDRAM fitted in this test
    wire [12:0] sdram_addr;
    wire [1:0]  sdram_ba, sdram_dqm;
    wire sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [3:0] vr, vg, vb;
    wire vs, hs, xclk, cam_rst_n, cam_pwdn;
    wire [7:0] lcd_data;
    wire lcd_rs, lcd_e, buzz;
    wire [15:0] led;

    reg  pc_tx = 1'b1;
    wire fpga_tx;

    top dut (
        .clk(clk), .rst_n(rst_n), .key(4'b1111),
        .sw_plain(1'b0), .sw_noavg(1'b0), .sw_mute(1'b0), .sw_ovl_off(1'b0), .sw_raw(1'b0),
        .btn_capture(1'b0),
        .cmos_pclk(pclk), .cmos_href(href), .cmos_vsync(vsync), .cmos_db(cdata),
        .cmos_sda(sda), .cmos_scl(scl), .cmos_rst_n(cam_rst_n), .cmos_pwdn(cam_pwdn), .cmos_xclk(xclk),
        .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n), .sdram_addr(sdram_addr), .sdram_ba(sdram_ba),
        .sdram_dqm(sdram_dqm), .sdram_dq(sdram_dq),
        .vga_out_r(vr), .vga_out_g(vg), .vga_out_b(vb), .vga_out_vs(vs), .vga_out_hs(hs),
        .uart_rxd(pc_tx), .uart_txd(fpga_tx),
        .lcd_data(lcd_data), .lcd_rs(lcd_rs), .lcd_e(lcd_e), .buzzer_out(buzz), .led(led));

    // XCLK frequency check
    realtime t_x0 = 0, t_x1 = 0;
    integer nx = 0;
    always @(posedge xclk) begin
        if (nx == 100) t_x0 = $realtime;
        if (nx == 1100) begin
            t_x1 = $realtime;
            $display(" XCLK %0.3f MHz (expect 21.333)", 1000.0 * 1000.0 / (t_x1 - t_x0));
        end
        nx = nx + 1;
    end

    //--------------------------------------------------------------------------
    // PC side
    //--------------------------------------------------------------------------
    task pc_send(input [7:0] b);
        integer i;
        begin
            pc_tx = 0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin pc_tx = b[i]; #(BIT_NS); end
            pc_tx = 1; #(BIT_NS);
        end
    endtask

    integer fd, nrx = 0, j;
    reg [7:0] rb;
    initial begin
        fd = $fopen("rx.hex", "w");
        forever begin
            @(negedge fpga_tx);
            #(BIT_NS * 1.5);
            for (j = 0; j < 8; j = j + 1) begin rb[j] = fpga_tx; #(BIT_NS); end
            if (fpga_tx !== 1'b1) $display(" ERROR: framing error on uart_txd at %0t", $time);
            $fdisplay(fd, "%02x", rb);
            nrx = nrx + 1;
        end
    end

    // results, seen through the hierarchy, with the LEDs a person would see
    integer nres = 0;
    reg tog_d = 0;
    always @(posedge dut.clk_core) begin
        tog_d <= dut.res_tog;
        if (dut.locked && dut.res_tog != tog_d) begin
            nres = nres + 1;
            #2000;
            $display(" [%0.2f ms] result %0d: state %0d score %0d avg %0d  LEDs %b_%b",
                     $time / 1.0e6, nres, dut.res_state, dut.res_score, dut.res_avg, led[15:8], led[7:0]);
        end
    end

    reg [7:0] photo [0:4799];
    integer k, want, t;
    task wait_rx(input integer n, input integer timeout_ms);
        begin
            want = nrx + n;
            t = 0;
            while (nrx < want && t < timeout_ms * 100) begin #10000; t = t + 1; end
            if (nrx < want) $display(" ERROR: only %0d of %0d bytes received", nrx - (want - n), n);
            #2000;
        end
    endtask

    initial begin
        $readmemh("photo.hex", photo);
        #1000 rst_n = 1;
        wait (dut.locked);
        $display(" [%0.3f ms] MMCM locked", $time / 1.0e6);
        #50000;
        pc_send("v");          wait_rx(15, 5);
        wait (nres >= INFER_WAIT);
        pc_send("g");          wait_rx(4826, 300);
        pc_send("s");          wait_rx(42, 300);
        pc_send(8'hA5);
        for (k = 0; k < 4800; k = k + 1) pc_send(photo[k]);
        wait_rx(4, 600);
        $display(" LEDs after the photo: %b_%b (led0 crossing, led1 not sure, led2 none)", led[15:8], led[7:0]);
        pc_send("r");          wait_rx(1, 5);
        $fclose(fd);
        $display(" DONE: %0d bytes, %0d results, camera frames committed %0d, SDRAM clock toggling %0d",
                 nrx, nres, dut.frame_cnt, sdram_clk !== 1'bx);
        $finish;
    end

    initial begin
        #900_000_000;
        $display(" ERROR: global timeout");
        $finish;
    end
endmodule
