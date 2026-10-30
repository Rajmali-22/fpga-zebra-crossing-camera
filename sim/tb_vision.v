`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// tb_vision.v  -  the detection path end to end, with a serial "PC":
//
//   OV7670 model -> vision (preproc, frame buffer, BCNN engine, uart_link)
//   PC model <-> 5,333,333 baud serial line <-> uart_rx / uart_tx (the RTL ones)
//
// The PC sends: 'v', then waits for INFER_WAIT camera inferences and sends 'g',
// 's', 'p', a photo upload (A5 + photo.hex), 'g', 'r'. Every byte received is
// written to rx.hex; sim/check_vision.py splits and checks them.
//------------------------------------------------------------------------------

module tb_vision;
    parameter INFER_WAIT = 2;
    parameter NFRAMES    = 2;
    parameter CORE_HALF  = 10.0;            // 50 MHz core clock
    parameter CORE_HZ    = 50_000_000;
    parameter SW_RAW     = 0;               // 1: no auto-contrast

    localparam real BIT_NS = 1.0e9 / 5333333.333;

    reg clk_sys = 0, clk_core = 0, clk_vga = 0;
    always #3.75 clk_sys = ~clk_sys;
    always #(CORE_HALF) clk_core = ~clk_core;
    always #20 clk_vga = ~clk_vga;

    reg rst_n = 0;

    // camera
    wire pclk, href, vsync;
    wire [7:0] cdata;
    wire [31:0] sent;
    ov7670_model #(.NFRAMES(NFRAMES), .HBLANK(16)) cam (
        .run(rst_n), .pclk(pclk), .href(href), .vsync(vsync), .data(cdata), .frames_sent(sent));

    // UART (RTL)
    reg  pc_tx = 1'b1;                  // PC -> FPGA line
    wire fpga_tx;                       // FPGA -> PC line
    wire [7:0] rx_data, tx_data;
    wire rx_valid, tx_wr, tx_busy, link_busy;

    uart_rx #(.CLK_FREQ(133_333_333), .BAUD(5_333_333)) u_rx (
        .clk(clk_sys), .rst_n(rst_n), .rx(pc_tx), .dout(rx_data), .valid(rx_valid));
    uart_tx #(.CLK_FREQ(133_333_333), .BAUD(5_333_333)) u_tx (
        .clk(clk_sys), .rst_n(rst_n), .din(tx_data), .wr_en(tx_wr), .tx(fpga_tx), .busy(tx_busy));

    wire res_tog, res_src, res_paused, res_stretched, core_busy, frame_tog;
    wire [1:0] res_state;
    wire [15:0] res_score, frame_cnt;
    wire signed [15:0] res_thr, res_margin, res_avg;
    wire [7:0] res_fps, vga_th_rdata;

    vision #(.CORE_HZ(CORE_HZ)) dut (
        .clk_sys(clk_sys), .rst_n_sys(rst_n), .clk_core(clk_core), .rst_n_core(rst_n),
        .clk_vga(clk_vga),
        .cmos_pclk(pclk), .cmos_href(href), .cmos_vsync(vsync), .cmos_db(cdata),
        .rx_data(rx_data), .rx_valid(rx_valid), .tx_busy(tx_busy),
        .tx_data(tx_data), .tx_wr(tx_wr), .cap_busy(1'b0), .link_busy(link_busy),
        .sw_plain(1'b0), .sw_noavg(1'b0), .sw_raw(SW_RAW[0]), .cam_led(4'b0110),
        .vga_th_raddr(13'd0), .vga_th_rdata(vga_th_rdata),
        .res_tog(res_tog), .res_state(res_state), .res_src(res_src),
        .res_score(res_score), .res_thr(res_thr), .res_margin(res_margin), .res_avg(res_avg),
        .res_fps(res_fps), .res_paused(res_paused), .res_stretched(res_stretched), .core_busy(core_busy),
        .frame_tog(frame_tog), .frame_cnt(frame_cnt));

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

    // receiver: every byte to rx.hex
    integer fd, nrx = 0;
    reg [7:0] rb;
    integer j;
    initial begin
        fd = $fopen("rx.hex", "w");
        forever begin
            @(negedge fpga_tx);
            #(BIT_NS * 1.5);
            for (j = 0; j < 8; j = j + 1) begin rb[j] = fpga_tx; #(BIT_NS); end
            if (fpga_tx !== 1'b1) $display(" ERROR: framing error on FPGA tx at %0t", $time);
            $fdisplay(fd, "%02x", rb);
            nrx = nrx + 1;
        end
    end

    // result log
    integer nres = 0;
    reg tog_d = 0;
    always @(posedge clk_core) begin
        tog_d <= res_tog;
        if (rst_n && res_tog != tog_d) begin
            nres = nres + 1;
            $display(" [%0.2f ms] result %0d: state %0d src %0d score %0d thr %0d margin %0d avg %0d",
                     $time / 1.0e6, nres, res_state, res_src, res_score, res_thr, res_margin, res_avg);
        end
    end

    reg [7:0] photo [0:4799];
    integer k, want;

    task wait_rx(input integer n, input integer timeout_ms);
        integer t;
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
        #500 rst_n = 1;
        #20000;

        $display(" PC: 'v'");
        pc_send("v");         wait_rx(15, 5);

        wait (nres >= INFER_WAIT);
        $display(" PC: 'g' after %0d results", nres);
        pc_send("g");         wait_rx(4826, 300);
        $display(" PC: 's'");
        pc_send("s");         wait_rx(42, 300);
        $display(" PC: 'p'");
        pc_send("p");         wait_rx(1, 5);
        $display(" PC: photo upload");
        pc_send(8'hA5);
        for (k = 0; k < 4800; k = k + 1) pc_send(photo[k]);
        wait_rx(4, 600);
        $display(" PC: 'g' (paused, photo)");
        pc_send("g");         wait_rx(4826, 300);
        $display(" PC: 'r'");
        pc_send("r");         wait_rx(1, 5);

        $fclose(fd);
        $display(" DONE: %0d bytes received, %0d results, %0d camera frames committed", nrx, nres, frame_cnt);
        $finish;
    end

    initial begin
        #900_000_000;
        $display(" ERROR: global timeout");
        $finish;
    end
endmodule
