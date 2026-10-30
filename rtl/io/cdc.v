`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// cdc.v  -  clock-domain-crossing helpers
//
// cdc_bit     : 2-flop synchroniser for one level signal
// cdc_toggle  : event crossing. The source flips "tog" once per event and keeps
//               the accompanying data bundle stable until the next event (all
//               events in this design are milliseconds apart). The destination
//               pulses "pulse" for one clock when it sees the flip; from that
//               cycle on the bundle can be sampled safely.
// reset_sync  : asynchronous assert, synchronous release
//
// Every first-stage flop carries ASYNC_REG so Vivado keeps the pair together
// and reports MTBF; the clock groups are declared asynchronous in the XDC.
//------------------------------------------------------------------------------

module cdc_bit #(
    parameter INIT = 1'b0
)(
    input  wire clk,
    input  wire d,
    output wire q
);
    (* ASYNC_REG = "TRUE" *) reg s1 = INIT, s2 = INIT;
    always @(posedge clk) begin
        s1 <= d;
        s2 <= s1;
    end
    assign q = s2;
endmodule


module cdc_toggle (
    input  wire clk,        // destination clock
    input  wire tog,        // source-domain toggle
    output reg  pulse = 1'b0
);
    (* ASYNC_REG = "TRUE" *) reg s1 = 1'b0, s2 = 1'b0;
    reg s3 = 1'b0;
    always @(posedge clk) begin
        s1    <= tog;
        s2    <= s1;
        s3    <= s2;
        pulse <= s2 ^ s3;
    end
endmodule


module reset_sync (
    input  wire clk,
    input  wire arst_n,     // asynchronous, active low
    output wire rst_n       // released synchronously to clk
);
    (* ASYNC_REG = "TRUE" *) reg r1 = 1'b0, r2 = 1'b0;
    reg r3 = 1'b0;
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            r1 <= 1'b0; r2 <= 1'b0; r3 <= 1'b0;
        end else begin
            r1 <= 1'b1; r2 <= r1; r3 <= r2;
        end
    end
    assign rst_n = r3;
endmodule
