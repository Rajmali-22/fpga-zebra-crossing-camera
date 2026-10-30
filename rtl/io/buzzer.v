`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// buzzer.v  -  audible alert while a zebra crossing is detected.
// 2.5 kHz square wave, 150 ms on / 350 ms off. A square wave also sounds on an
// active (self-oscillating) buzzer, so the board's buzzer type does not matter.
// The EDGE board needs the buzzer jumper (J6) on "Enable".
//------------------------------------------------------------------------------

module buzzer #(
    parameter CLK_HZ  = 50_000_000,
    parameter TONE_HZ = 2500
)(
    input  wire clk,
    input  wire rst_n,
    input  wire enable,
    output reg  out
);
    localparam integer HALF = CLK_HZ / (2 * TONE_HZ);
    localparam integer MS   = CLK_HZ / 1000;

    reg [$clog2(HALF)-1:0] div;
    reg [$clog2(MS)-1:0]   ms_div;
    reg [8:0]              ms;            // 0..499 ms cadence
    reg                    tone;

    always @(posedge clk) begin
        if (!rst_n) begin
            div <= 0; ms_div <= 0; ms <= 0; tone <= 0; out <= 0;
        end else begin
            div  <= (div == HALF - 1) ? 0 : div + 1'b1;
            if (div == HALF - 1) tone <= ~tone;
            ms_div <= (ms_div == MS - 1) ? 0 : ms_div + 1'b1;
            if (ms_div == MS - 1) ms <= (ms == 499) ? 0 : ms + 1'b1;
            if (!enable) ms <= 0;
            out <= enable && (ms < 150) && tone;
        end
    end
endmodule
