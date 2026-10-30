`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// hd44780_model.v  -  enough of an HD44780 to read back what was written:
// commands set the DDRAM address (0x80 | addr) or clear (0x01); data bytes are
// stored at the address, which then increments. Line 1 = 0x00.., line 2 = 0x40..
//------------------------------------------------------------------------------

module hd44780_model (
    input wire       e,
    input wire       rs,
    input wire [7:0] d
);
    reg [7:0] ddram [0:127];
    reg [6:0] ac = 0;
    integer   ncmd = 0, ndat = 0, i;

    initial for (i = 0; i < 128; i = i + 1) ddram[i] = 8'h20;

    always @(negedge e) begin
        if (!rs) begin
            ncmd = ncmd + 1;
            if (d[7]) ac = d[6:0];
            else if (d == 8'h01) begin
                for (i = 0; i < 128; i = i + 1) ddram[i] = 8'h20;
                ac = 0;
            end
        end else begin
            ndat = ndat + 1;
            ddram[ac] = d;
            ac = ac + 1;
        end
    end

    task show;
        integer k;
        begin
            $write(" LCD line 1: |");
            for (k = 0; k < 16; k = k + 1) $write("%c", ddram[k]);
            $write("|\n LCD line 2: |");
            for (k = 64; k < 80; k = k + 1) $write("%c", ddram[k]);
            $display("|\n LCD commands %0d, characters %0d", ncmd, ndat);
        end
    endtask
endmodule
