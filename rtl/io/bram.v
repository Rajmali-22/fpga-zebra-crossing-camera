`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// bram_sdp  -  simple dual-port block RAM, one write port and one read port,
//              each on its own clock (Xilinx inference template).
//              Read latency: 1 clock of rclk.
//------------------------------------------------------------------------------

module bram_sdp #(
    parameter AW = 13,
    parameter DW = 8
)(
    input  wire          wclk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,

    input  wire          rclk,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);
    (* ram_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
        rdata = {DW{1'b0}};
    end

    always @(posedge wclk)
        if (we) mem[waddr] <= wdata;

    always @(posedge rclk)
        rdata <= mem[raddr];
endmodule
