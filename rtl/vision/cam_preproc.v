`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// cam_preproc.v  -  OV7670 pixel stream -> 80x60 grayscale network input
//
// Listens to the camera pins in parallel with camera_interface (which keeps
// feeding SDRAM / VGA unchanged) and produces exactly what the BCNN expects,
// bit for bit identical to python/cam_golden.py:
//
//   RGB565 -> RGB888 by bit replication (as capture_host.py does)
//   gray   = (77 R + 150 G + 29 B) >> 8          (bcnn_model.gray_u8)
//   out    = (sum of an 8x8 block of gray) >> 6  (bcnn_model.block_mean, 8)
//
// 640x480 divides exactly into 80x60 blocks of 8x8, so no divider is needed.
// Each finished block is written to the frame buffer at bank*BANK + y*80 + x.
// Two camera banks alternate (ping-pong): a frame is committed - the bank is
// published through frame_bank / frame_tog - only when all 480 lines had at
// least 640 pixels (extra pixels and lines are ignored); a broken frame is
// written again over the same bank.
//
// Sampling (clk = 133.33 MHz, PCLK = 21.33 MHz, i.e. ~6 clocks per PCLK):
// PCLK, HREF and VSYNC pass a 2-flop synchroniser plus one edge flop; the data
// byte is registered once. When the synchronised PCLK shows a rising edge, the
// registered byte was taken 7.5..15 ns after that edge - inside the 23 ns the
// OV7670 holds data (it changes on the falling edge). camera_interface samples
// at the same point.
//------------------------------------------------------------------------------

module cam_preproc #(
    parameter W     = 640,
    parameter H     = 480,
    parameter BANK  = 4800            // frame-buffer words per bank (80 x 60)
)(
    input  wire        clk,
    input  wire        rst_n,           // synchronous, active low

    input  wire        cmos_pclk,
    input  wire        cmos_href,
    input  wire        cmos_vsync,
    input  wire [7:0]  cmos_db,

    // frame-buffer write port
    output reg         fb_we,
    output reg  [13:0] fb_addr,
    output reg  [7:0]  fb_data,

    // latest complete frame
    output reg         frame_bank,      // bank (0/1) holding it
    output reg         frame_tog,       // flips once per committed frame
    output reg  [15:0] frame_cnt,       // committed frames

    // diagnostics (for the UART status command)
    output reg  [15:0] bad_frames,      // frames dropped (wrong line length / count)
    output reg  [10:0] last_line_len,   // pixels in the last line seen
    output reg  [9:0]  last_lines       // lines in the last frame seen
);

    //--------------------------------------------------------------------------
    // Input sampling
    //--------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg pclk_s0, pclk_s1;
    (* ASYNC_REG = "TRUE" *) reg href_s0, href_s1;
    (* ASYNC_REG = "TRUE" *) reg vs_s0,   vs_s1;
    reg pclk_s2, href_s2, vs_s2;
    reg [7:0] db_r;

    always @(posedge clk) begin
        pclk_s0 <= cmos_pclk;  pclk_s1 <= pclk_s0;  pclk_s2 <= pclk_s1;
        href_s0 <= cmos_href;  href_s1 <= href_s0;  href_s2 <= href_s1;
        vs_s0   <= cmos_vsync; vs_s1   <= vs_s0;    vs_s2   <= vs_s1;
        db_r    <= cmos_db;
    end

    wire pclk_rise = pclk_s1 & ~pclk_s2;
    wire href_fall = ~href_s1 & href_s2;
    wire vs_rise   = vs_s1 & ~vs_s2;

    //--------------------------------------------------------------------------
    // Byte pairing and raster position
    //--------------------------------------------------------------------------
    reg        phase;           // 0: next byte is the high byte
    reg [7:0]  hi_byte;
    reg [10:0] x;               // pixel index in the current line
    reg [9:0]  y;               // line index in the current frame
    reg        frame_ok;        // every line so far had exactly W pixels

    reg        p_valid;         // one RGB565 pixel at (p_x, p_y)
    reg [15:0] p_rgb;
    reg [9:0]  p_x, p_y;

    always @(posedge clk) begin
        if (!rst_n) begin
            phase <= 0; hi_byte <= 0; x <= 0; y <= 0; frame_ok <= 0;
            p_valid <= 0; p_rgb <= 0; p_x <= 0; p_y <= 0;
            last_line_len <= 0; last_lines <= 0;
        end else begin
            p_valid <= 0;

            if (vs_rise) begin                  // new frame
                last_lines <= y;
                x <= 0; y <= 0; phase <= 0;
                frame_ok <= 1;
            end else if (href_fall) begin       // end of a line
                last_line_len <= x;
                if (x < W) frame_ok <= 0;     // longer lines: first 640 pixels are used
                if (y != 10'h3FF) y <= y + 1'b1;
                x <= 0; phase <= 0;
            end else if (pclk_rise && href_s1) begin
                if (!phase) begin
                    hi_byte <= db_r;
                    phase   <= 1;
                end else begin
                    phase <= 0;
                    if (x < W && y < H) begin
                        p_valid <= 1;
                        p_rgb   <= {hi_byte, db_r};
                        p_x     <= x[9:0];
                        p_y     <= y;
                    end
                    if (x != 11'h7FF) x <= x + 1'b1;
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // Stage 1: RGB565 -> 8-bit gray
    //--------------------------------------------------------------------------
    wire [7:0] r8 = {p_rgb[15:11], p_rgb[15:13]};
    wire [7:0] g8 = {p_rgb[10:5],  p_rgb[10:9]};
    wire [7:0] b8 = {p_rgb[4:0],   p_rgb[4:2]};

    // two clocks: the three products, then their sum (one clock was too long
    // a path at 133 MHz; a pixel arrives only every ~12 clocks anyway)
    reg        m_valid, g_valid;
    reg [15:0] m_r, m_g, m_b;
    reg [15:0] g_sum;
    reg [9:0]  m_x, m_y, g_x, g_y;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_valid <= 0; m_r <= 0; m_g <= 0; m_b <= 0; m_x <= 0; m_y <= 0;
            g_valid <= 0; g_sum <= 0; g_x <= 0; g_y <= 0;
        end else begin
            m_valid <= p_valid;
            m_r     <= 8'd77  * r8;                           // max 19635
            m_g     <= 8'd150 * g8;                           // max 38250
            m_b     <= 8'd29  * b8;                           // max  7395
            m_x     <= p_x;
            m_y     <= p_y;
            g_valid <= m_valid;
            g_sum   <= m_r + m_g + m_b;                       // max 65280
            g_x     <= m_x;
            g_y     <= m_y;
        end
    end

    wire [7:0] gray = g_sum[15:8];

    //--------------------------------------------------------------------------
    // Stage 2: 8x8 block sums, one 14-bit accumulator per block column
    //--------------------------------------------------------------------------
    reg [13:0] acc [0:79];      // 64 x 255 = 16320 fits in 14 bits

    wire [6:0] bx = g_x[9:3];
    wire [5:0] by = g_y[8:3];
    wire       blk_first = (g_x[2:0] == 3'd0) && (g_y[2:0] == 3'd0);
    wire       blk_last  = (g_x[2:0] == 3'd7) && (g_y[2:0] == 3'd7);
    wire [13:0] acc_new  = (blk_first ? 14'd0 : acc[bx]) + gray;

    reg        wbank;                       // bank being written
    wire       frame_last = blk_last && (g_x == W - 1) && (g_y == H - 1);

    integer i;
    initial for (i = 0; i < 80; i = i + 1) acc[i] = 0;

    always @(posedge clk) begin
        if (g_valid)
            acc[bx] <= acc_new;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            fb_we <= 0; fb_addr <= 0; fb_data <= 0;
            wbank <= 0; frame_bank <= 0; frame_tog <= 0; frame_cnt <= 0;
            bad_frames <= 0;
        end else begin
            fb_we <= 0;
            if (g_valid && blk_last) begin
                fb_we   <= 1;
                fb_addr <= (wbank ? BANK : 0) + by * 7'd80 + bx;
                fb_data <= acc_new[13:6];
                if (frame_last) begin
                    // frame_ok covers lines 0..478; line 479 has just
                    // delivered its 640th pixel, so it is not short either
                    if (frame_ok) begin
                        frame_bank <= wbank;
                        frame_tog  <= ~frame_tog;
                        frame_cnt  <= frame_cnt + 1'b1;
                        wbank      <= ~wbank;
                    end else begin
                        bad_frames <= bad_frames + 1'b1;
                    end
                end
            end
        end
    end

endmodule
