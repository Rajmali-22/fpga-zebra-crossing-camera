`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// uart_rx : 8-N-1 UART receiver
//
//   Start bit is detected on the synchronised rx line, re-checked at the
//   half-bit point (false-start rejection), then the 8 data bits are sampled
//   at the centre of every bit period.  "valid" pulses for one clock when a
//   byte with a good stop bit is available on dout.
//////////////////////////////////////////////////////////////////////////////

module uart_rx
	#(
		parameter CLK_FREQ = 133_333_333,
		parameter BAUD     = 5_333_333 //133.33MHz/25, exact
	)
	(
		input  wire clk, rst_n,
		input  wire rx,
		output reg[7:0] dout,
		output reg valid
	);

	//rounded to nearest, same reasoning as uart_tx.v
	localparam integer DIV  = (CLK_FREQ + BAUD/2)/BAUD;
	localparam integer HALF = DIV/2;

	localparam[1:0] idle=0, start_chk=1, data=2, stop=3;

	reg[1:0]  state;
	reg[19:0] ctr;
	reg[3:0]  bit_cnt;
	reg[7:0]  sh;
	reg       rx_1, rx_2; //2-FF synchroniser (rx is asynchronous to clk)

	always @(posedge clk, negedge rst_n) begin
		if(!rst_n) begin
			rx_1    <= 1'b1;
			rx_2    <= 1'b1;
			state   <= idle;
			ctr     <= 0;
			bit_cnt <= 0;
			sh      <= 0;
			dout    <= 0;
			valid   <= 1'b0;
		end
		else begin
			rx_1  <= rx;
			rx_2  <= rx_1;
			valid <= 1'b0;

			case(state)
				  idle: if(rx_2 == 1'b0) begin //falling edge => possible start bit
							ctr   <= 0;
							state <= start_chk;
						  end
			start_chk: if(ctr == HALF-1) begin //re-sample in the middle of the start bit
							ctr <= 0;
							if(rx_2 == 1'b0) begin
								bit_cnt <= 0;
								state   <= data;
							end
							else state <= idle; //glitch, not a real start bit
						  end
						  else ctr <= ctr + 1'b1;
				  data: if(ctr == DIV-1) begin //sample in the middle of every data bit
							ctr <= 0;
							sh  <= {rx_2, sh[7:1]}; //UART is LSB first
							if(bit_cnt == 4'd7) state <= stop;
							else bit_cnt <= bit_cnt + 1'b1;
						  end
						  else ctr <= ctr + 1'b1;
				  stop: if(ctr == DIV-1) begin
							ctr   <= 0;
							state <= idle;
							if(rx_2 == 1'b1) begin //good stop bit -> byte accepted
								dout  <= sh;
								valid <= 1'b1;
							end
						  end
						  else ctr <= ctr + 1'b1;
			endcase
		end
	end

endmodule
