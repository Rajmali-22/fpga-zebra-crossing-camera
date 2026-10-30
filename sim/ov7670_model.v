`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// ov7670_model.v  -  behavioural OV7670 in RGB565 VGA mode, for testbenches
//
// Plays frames from frame<N>.hex (640x480 words, $readmemh) in a loop:
//   VSYNC high for VS_LINES line times, a few blank lines, then 480 lines of
//   HREF high with 1280 bytes (high byte first), data changing on PCLK falling
//   edges as on the real sensor.
// PCLK_IN_BLANK = 0 stops PCLK while HREF is low (COM10 bit 5, the setting the
// camera design uses); 1 keeps it running. BAD_LINE >= 0 makes that line of
// every odd frame 2 pixels short, to test frame rejection.
//------------------------------------------------------------------------------

module ov7670_model #(
    parameter real PCLK_NS       = 46.875,      // 21.333 MHz
    parameter      NFRAMES       = 2,           // frame0.hex .. frame<N-1>.hex
    parameter      HBLANK        = 144,         // PCLK periods between lines
    parameter      VS_LINES      = 3,
    parameter      VBLANK_LINES  = 2,
    parameter      PCLK_IN_BLANK = 0,
    parameter      BAD_LINE      = -1
)(
    input  wire       run,
    output reg        pclk  = 0,
    output reg        href  = 0,
    output reg        vsync = 0,
    output reg [7:0]  data  = 0,
    output reg [31:0] frames_sent = 0
);
    reg [15:0] img [0:640*480-1];
    reg        gate = 0;          // PCLK enabled

    // free-running PCLK source, gated
    reg pclk_src = 0;
    always #(PCLK_NS/2) pclk_src = ~pclk_src;
    always @(*) pclk = pclk_src & gate;

    task pclk_cycles(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(negedge pclk_src);
        end
    endtask

    integer f, ln, px, len;
    reg [8*16-1:0] fname;
    initial begin
        wait (run);
        for (f = 0; ; f = f + 1) begin
            $sformat(fname, "frame%0d.hex", f % NFRAMES);
            $readmemh(fname, img);
            // vertical sync
            gate = PCLK_IN_BLANK;
            @(negedge pclk_src);
            vsync = 1;
            pclk_cycles(VS_LINES * (1280 + HBLANK));
            vsync = 0;
            pclk_cycles(VBLANK_LINES * (1280 + HBLANK));
            for (ln = 0; ln < 480; ln = ln + 1) begin
                len = (ln == BAD_LINE && (f % 2) == 1) ? 638 : 640;
                gate = 1;
                for (px = 0; px < len; px = px + 1) begin
                    @(negedge pclk_src);
                    href = 1;
                    data = img[ln*640 + px][15:8];
                    @(negedge pclk_src);
                    data = img[ln*640 + px][7:0];
                end
                @(negedge pclk_src);
                href = 0;
                data = 8'h00;
                gate = PCLK_IN_BLANK;
                pclk_cycles(HBLANK);
            end
            frames_sent = frames_sent + 1;
        end
    end
endmodule
