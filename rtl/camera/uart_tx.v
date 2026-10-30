`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// uart_tx : 8-N-1 UART transmitter
//
//   - Assert wr_en for ONE clock while busy==0 to load din.
//   - busy goes high on the very same clock edge that samples wr_en, so the
//     cycle right after the load already reads busy==1 (no dead-time needed
//     between the load and the next "if(!busy)" poll).
//   - tx idles high.
//////////////////////////////////////////////////////////////////////////////

module uart_tx
	#(
		parameter CLK_FREQ = 133_333_333, //frequency of "clk" in Hz
		parameter BAUD     = 5_333_333    //bits per second (133.33MHz/25, exact)
	)
	(
		input  wire clk, rst_n,
		input  wire[7:0] din,
		input  wire wr_en,   //1-clk pulse, only honoured while busy==0
		output reg  tx,
		output reg  busy
	);

	//Clocks per bit, ROUNDED TO NEAREST rather than truncated. At high baud
	//rates the divisor is small and truncation is a big relative error:
	//150MHz/9M truncates to 16 (+4.2% off) but rounds to 17 (-2.0% off).
	//8-N-1 samples the stop bit 9.5 bit-times after the start edge, so the
	//combined FPGA+PC error must stay well under 1/9.5 = 5.3%.
	localparam integer DIV = (CLK_FREQ + BAUD/2)/BAUD;
	localparam integer ACTUAL_BAUD = CLK_FREQ/DIV; //what really comes out

	initial begin
		if(DIV < 2) $display("uart_tx WARNING: BAUD=%0d too high for CLK_FREQ=%0d", BAUD, CLK_FREQ);
		else $display("uart_tx: DIV=%0d, requested %0d baud, actual %0d baud", DIV, BAUD, ACTUAL_BAUD);
	end

	reg[19:0] baud_ctr;
	reg[3:0]  bit_cnt;
	reg[9:0]  shifter;  //{stop , data[7:0] , start}

	always @(posedge clk, negedge rst_n) begin
		if(!rst_n) begin
			tx       <= 1'b1;
			busy     <= 1'b0;
			baud_ctr <= 0;
			bit_cnt  <= 0;
			shifter  <= 10'h3FF;
		end
		else if(!busy) begin
			tx       <= 1'b1;
			baud_ctr <= 0;
			bit_cnt  <= 0;
			if(wr_en) begin
				shifter <= {1'b1, din, 1'b0}; //stop bit , payload , start bit
				tx      <= 1'b0;              //start bit goes on the wire now
				busy    <= 1'b1;
			end
		end
		else begin
			if(baud_ctr == DIV-1) begin
				baud_ctr <= 0;
				shifter  <= {1'b1, shifter[9:1]};
				tx       <= shifter[1];
				if(bit_cnt == 4'd9) busy <= 1'b0; //start+8data+stop all shifted out
				else bit_cnt <= bit_cnt + 1'b1;
			end
			else baud_ctr <= baud_ctr + 1'b1;
		end
	end

endmodule
