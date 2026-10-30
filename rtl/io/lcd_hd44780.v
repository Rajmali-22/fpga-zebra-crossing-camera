`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// lcd_hd44780.v  -  16x2 character LCD on the EDGE board (8-bit bus, RS, E;
// R/W is tied to ground on the board, so the busy flag cannot be read and every
// command simply waits longer than the HD44780 datasheet maximum).
//
// Power-up: 50 ms, 0x38 x3 (4.5 ms, 150 us, 150 us), 0x38, 0x08, 0x01 (2 ms),
// 0x06, 0x0C. Then forever: 0x80 + 16 characters of line1, 0xC0 + 16 of line2,
// 100 ms pause. Each write: RS and data set, 1 us, E high 2 us, E low, 50 us.
//------------------------------------------------------------------------------

module lcd_hd44780 #(
    parameter CLK_HZ = 50_000_000
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [127:0] line1,
    input  wire [127:0] line2,
    output reg  [7:0]   lcd_data,
    output reg          lcd_rs,
    output reg          lcd_e
);
    localparam integer US = CLK_HZ / 1_000_000;

    reg [$clog2(US)-1:0] us_div;
    wire us_tick = (us_div == US - 1);
    always @(posedge clk) begin
        if (!rst_n) us_div <= 0;
        else        us_div <= us_tick ? 0 : us_div + 1'b1;
    end

    // step list: {rs, byte, wait_us}
    reg [3:0]   step;          // init steps 0..8, then 9 = refresh loop
    reg [5:0]   pos;           // 0: line-1 address, 1..16 chars, 17: line-2 address, 18..33 chars
    reg [16:0]  wait_us;
    reg [1:0]   phase;         // 0 setup, 1 E high, 2 hold/wait
    reg [16:0]  t;
    reg [127:0] l1, l2;

    reg        nxt_rs;
    reg [7:0]  nxt_byte;
    reg [16:0] nxt_wait;
    always @(*) begin
        nxt_rs = 0; nxt_byte = 8'h00; nxt_wait = 17'd100;
        case (step)
            4'd0: begin nxt_byte = 8'h38; nxt_wait = 17'd4500; end
            4'd1: begin nxt_byte = 8'h38; nxt_wait = 17'd150;  end
            4'd2: begin nxt_byte = 8'h38; nxt_wait = 17'd150;  end
            4'd3: begin nxt_byte = 8'h38; nxt_wait = 17'd100;  end
            4'd4: begin nxt_byte = 8'h08; nxt_wait = 17'd100;  end
            4'd5: begin nxt_byte = 8'h01; nxt_wait = 17'd2000; end
            4'd6: begin nxt_byte = 8'h06; nxt_wait = 17'd100;  end
            4'd7: begin nxt_byte = 8'h0C; nxt_wait = 17'd100;  end
            default: begin
                if (pos == 0)       begin nxt_byte = 8'h80; nxt_wait = 17'd50; end
                else if (pos < 17)  begin nxt_rs = 1; nxt_byte = l1[8*(16-pos) +: 8]; nxt_wait = 17'd50; end
                else if (pos == 17) begin nxt_byte = 8'hC0; nxt_wait = 17'd50; end
                else begin
                    nxt_rs = 1; nxt_byte = l2[8*(33-pos) +: 8];
                    nxt_wait = (pos == 33) ? 17'd100000 : 17'd50;
                end
            end
        endcase
    end

    localparam P_POWER = 2'd3;

    always @(posedge clk) begin
        if (!rst_n) begin
            step <= 0; pos <= 0; phase <= P_POWER; t <= 17'd50000; wait_us <= 0;
            lcd_data <= 0; lcd_rs <= 0; lcd_e <= 0; l1 <= 0; l2 <= 0;
        end else if (us_tick) begin
            case (phase)
                P_POWER: begin                          // 50 ms after power-up
                    if (t != 0) t <= t - 1'b1;
                    else begin
                        lcd_rs <= nxt_rs; lcd_data <= nxt_byte; wait_us <= nxt_wait;
                        phase <= 2'd0;
                    end
                end
                2'd0: begin                             // RS / data set up (1 us)
                    lcd_e <= 1;
                    t     <= 2;
                    phase <= 2'd1;
                end
                2'd1: begin                             // E high 2 us
                    if (t != 1) t <= t - 1'b1;
                    else begin
                        lcd_e <= 0;
                        t     <= wait_us;
                        phase <= 2'd2;
                    end
                end
                2'd2: begin                             // execution time
                    if (t != 0) t <= t - 1'b1;
                    else begin
                        if (step < 4'd8) step <= step + 1'b1;
                        else begin
                            if (pos == 0) begin l1 <= line1; l2 <= line2; end
                            pos <= (pos == 33) ? 6'd0 : pos + 1'b1;
                        end
                        phase <= 2'd3;                  // load next on the next tick
                        t <= 0;
                    end
                end
            endcase
        end
    end
endmodule
