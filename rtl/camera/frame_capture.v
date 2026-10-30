`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// frame_capture : "take a photo and upload it to the PC" engine
//
// Runs entirely in the SDRAM clock domain (same clk as sdram_interface).
//
// SEQUENCE
//   1. Wait for a command byte on the UART:
//        'c' / 'C'  ->  full resolution   640x480 RGB565
//        'd' / 'D'  ->  half resolution   320x240 RGB565 (2x2 decimation,
//                                          ~4x faster upload)
//   2. Wait for "frame_sync" (sdram_interface just issued the LAST burst of a
//      frame) so that SDRAM rows 0..599 hold one complete, non-torn frame.
//   3. Assert freeze + cam_pause:
//        freeze    -> sdram_interface stops writing camera data to SDRAM and
//                     holds its write pointer at 0, so the frame is preserved.
//                     VGA keeps reading, so the monitor shows the frozen shot.
//        cam_pause -> camera_interface parks its pixel FSM at a frame boundary
//                     and stops pushing pixels into the camera FIFO.
//   4. Send the 10-byte header, then burst-read the 600 SDRAM rows one at a
//      time into a 1024x16 buffer and drain them out of the UART, then the
//      2-byte trailer.
//   5. Flush the camera FIFO, let the counters settle, then release
//      cam_pause/freeze together.  The camera FSM restarts on the next VSYNC
//      falling edge with the SDRAM write pointer back at 0, so live view
//      resumes perfectly frame-aligned.
//
// WIRE FORMAT
//   header  : A5 5A 0F F0  W[15:8] W[7:0]  H[15:8] H[7:0]  bpp(=2) fmt(=1)
//   payload : W*H pixels, 2 bytes each, RGB565 HIGH byte first, raster order
//   trailer : 5A A5
//////////////////////////////////////////////////////////////////////////////

module frame_capture
	#(
		parameter H_ACTIVE         = 640,
		parameter V_ACTIVE         = 480,
		parameter WORDS_PER_BURST  = 512, //SDRAM full-page burst length
		parameter BURSTS_PER_FRAME = 600  //H_ACTIVE*V_ACTIVE/WORDS_PER_BURST
	)
	(
		input  wire clk, rst_n,

		//hardware trigger (debounced 1-clk pulse), takes a full-res shot
		input  wire      btn_tick,

		//UART side
		input  wire[7:0] rx_data,
		input  wire      rx_valid,
		output reg[7:0]  tx_data,
		output reg       tx_wr,
		input  wire      tx_busy,

		//handshake with sdram_interface
		output reg        freeze,      //1 = hold the frame, no camera writes
		output reg        cam_pause,   //1 = park the camera pixel FSM
		output reg        cam_fifo_flush,
		input  wire       frame_sync,  //pulse: last burst of a frame was issued
		output reg        cap_rd_req,
		output reg[14:0]  cap_rd_addr,
		input  wire       cap_rd_ack,
		input  wire[15:0] cap_data,
		input  wire       cap_data_valid,

		output wire       cap_busy
	);

	//FSM state declarations
	localparam[3:0] s_idle   = 0,
						 s_arm    = 1,
						 s_hdr    = 2,
						 s_req    = 3,
						 s_pop    = 4,
						 s_txhi   = 5,
						 s_txlo   = 6,
						 s_trl    = 7,
						 s_flush  = 8,
						 s_settle = 9;

	reg[3:0]  state_q;
	reg       mode_half;              //0 = 640x480 , 1 = 320x240
	reg[9:0]  burst_ctr;              //0..BURSTS_PER_FRAME-1
	reg[9:0]  word_ctr;               //0..WORDS_PER_BURST
	reg[9:0]  pix_x, pix_y;           //raster position inside the frame
	reg[3:0]  hdr_idx;                //0..9 header , 10..11 trailer
	reg[15:0] pixel;
	reg[15:0] dly;

	//buffer between the (fast, un-stallable) SDRAM burst and the (slow) UART
	wire[15:0] fifo_dout;
	wire       fifo_empty;
	wire       buf_flush = (state_q==s_idle) || (state_q==s_arm);
	//NOTE: "pop" must be combinational so that the word presented on fifo_dout
	//in this very clock is the one we latch (the FIFO is first-word-fall-through).
	wire       pop = (state_q==s_pop) && (word_ctr!=WORDS_PER_BURST) && !fifo_empty;

	//header / trailer byte ROM
	wire[15:0] out_w = mode_half? (H_ACTIVE/2) : H_ACTIVE;
	wire[15:0] out_h = mode_half? (V_ACTIVE/2) : V_ACTIVE;
	reg[7:0] hdr_byte;
	always @* begin
		case(hdr_idx)
			4'd0 : hdr_byte = 8'hA5;      //magic
			4'd1 : hdr_byte = 8'h5A;
			4'd2 : hdr_byte = 8'h0F;
			4'd3 : hdr_byte = 8'hF0;
			4'd4 : hdr_byte = out_w[15:8];
			4'd5 : hdr_byte = out_w[7:0];
			4'd6 : hdr_byte = out_h[15:8];
			4'd7 : hdr_byte = out_h[7:0];
			4'd8 : hdr_byte = 8'd2;       //bytes per pixel
			4'd9 : hdr_byte = 8'h01;      //format: RGB565, high byte first
			4'd10: hdr_byte = 8'h5A;      //trailer
			4'd11: hdr_byte = 8'hA5;
			default: hdr_byte = 8'h00;
		endcase
	end

	always @(posedge clk, negedge rst_n) begin
		if(!rst_n) begin
			state_q        <= s_idle;
			freeze         <= 1'b0;
			cam_pause      <= 1'b0;
			cam_fifo_flush <= 1'b0;
			cap_rd_req     <= 1'b0;
			cap_rd_addr    <= 0;
			tx_wr          <= 1'b0;
			tx_data        <= 0;
			mode_half      <= 1'b0;
			burst_ctr      <= 0;
			word_ctr       <= 0;
			pix_x          <= 0;
			pix_y          <= 0;
			hdr_idx        <= 0;
			pixel          <= 0;
			dly            <= 0;
		end
		else begin
			tx_wr <= 1'b0; //default: no UART load this cycle

			case(state_q)

				//----------------------------------------------------------
				s_idle: begin
					freeze         <= 1'b0;
					cam_pause      <= 1'b0;
					cam_fifo_flush <= 1'b0;
					if(rx_valid) begin
						if(rx_data==8'h43 || rx_data==8'h63) begin //'C'/'c'
							mode_half <= 1'b0;
							state_q   <= s_arm;
						end
						else if(rx_data==8'h44 || rx_data==8'h64) begin //'D'/'d'
							mode_half <= 1'b1;
							state_q   <= s_arm;
						end
					end
					else if(btn_tick) begin //push-button = full resolution shot
						mode_half <= 1'b0;
						state_q   <= s_arm;
					end
				end

				//---- wait for a frame boundary, then freeze it ------------
				s_arm: if(frame_sync) begin
							freeze    <= 1'b1;
							cam_pause <= 1'b1;
							burst_ctr <= 0;
							word_ctr  <= 0;
							pix_x     <= 0;
							pix_y     <= 0;
							hdr_idx   <= 0;
							state_q   <= s_hdr;
						 end

				//---- 10-byte header --------------------------------------
				s_hdr: if(!tx_busy && !tx_wr) begin
							tx_data <= hdr_byte;
							tx_wr   <= 1'b1;
							if(hdr_idx == 4'd9) state_q <= s_req;
							else hdr_idx <= hdr_idx + 1'b1;
						 end

				//---- ask sdram_interface for one full-page burst ----------
				s_req: begin
							cap_rd_addr <= {5'b0, burst_ctr};
							cap_rd_req  <= 1'b1;
							if(cap_rd_ack) begin
								cap_rd_req <= 1'b0;
								word_ctr   <= 0;
								state_q    <= s_pop;
							end
						 end

				//---- drain the burst, pixel by pixel ---------------------
				s_pop: if(word_ctr == WORDS_PER_BURST) begin
							if(burst_ctr == BURSTS_PER_FRAME-1) begin
								hdr_idx <= 4'd10;
								state_q <= s_trl;
							end
							else begin
								burst_ctr <= burst_ctr + 1'b1;
								state_q   <= s_req;
							end
						 end
						 else if(pop) begin
							pixel    <= fifo_dout;
							word_ctr <= word_ctr + 1'b1;
							//advance the raster position
							if(pix_x == H_ACTIVE-1) begin
								pix_x <= 0;
								pix_y <= pix_y + 1'b1;
							end
							else pix_x <= pix_x + 1'b1;
							//in half-res mode only even columns of even rows are sent
							if(!mode_half || (~pix_x[0] && ~pix_y[0])) state_q <= s_txhi;
						 end

				s_txhi: if(!tx_busy && !tx_wr) begin
							tx_data <= pixel[15:8];
							tx_wr   <= 1'b1;
							state_q <= s_txlo;
						 end

				s_txlo: if(!tx_busy && !tx_wr) begin
							tx_data <= pixel[7:0];
							tx_wr   <= 1'b1;
							state_q <= s_pop;
						 end

				//---- 2-byte trailer --------------------------------------
				s_trl: if(!tx_busy && !tx_wr) begin
							tx_data <= hdr_byte;
							tx_wr   <= 1'b1;
							if(hdr_idx == 4'd11) begin
								cam_fifo_flush <= 1'b1;
								dly            <= 0;
								state_q        <= s_flush;
							end
							else hdr_idx <= hdr_idx + 1'b1;
						 end

				//---- empty the stale camera FIFO -------------------------
				s_flush: if(dly == 16'd63) begin
								cam_fifo_flush <= 1'b0;
								dly            <= 0;
								state_q        <= s_settle;
							end
							else dly <= dly + 1'b1;

				//---- let data_count_r settle back to 0 BEFORE unfreezing --
				s_settle: if(dly == 16'd255) begin
								freeze    <= 1'b0;
								cam_pause <= 1'b0;
								state_q   <= s_idle;
							 end
							 else dly <= dly + 1'b1;

				default: state_q <= s_idle;
			endcase
		end
	end

	assign cap_busy = (state_q != s_idle);

	//module instantiations
	asyn_fifo #(.DATA_WIDTH(16),.FIFO_DEPTH_WIDTH(10)) m0 //1024x16, holds one 512-word burst
	(
		.rst_n(rst_n && !buf_flush),
		.clk_write(clk),
		.clk_read(clk),
		.write(cap_data_valid),
		.read(pop),
		.data_write(cap_data),
		.data_read(fifo_dout),
		.full(),
		.empty(fifo_empty),
		.data_count_w(),
		.data_count_r()
	);

endmodule
