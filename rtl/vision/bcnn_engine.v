`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// bcnn_engine.v  -  runs the v3 BCNN on camera frames (and on photos sent from
// the PC), and turns scores into a stable decision. Clock: clk_core.
//
// Job order when the core is free:
//   1. a photo uploaded over UART (bank 2)              -> answer goes to the PC
//   2. a pending UART snapshot, if a new result exists  -> hold still for it
//   3. the newest complete camera frame (bank 0/1)
//
// Auto-contrast (camera frames, unless sw_raw): the OV7670 delivers flat,
// washed-out pictures (a real frame from this board spans gray 58..148), which
// cost v3 up to 30 points of accuracy (python/robustness.py). Each frame is
// stretched before the network sees it:
//   histogram of the 4800 pixels -> lo = 25th darkest, hi = 25th brightest
//   (ignores 0.5 % at each end, so a lamp or a dark corner does not defeat it)
//   scale = 65280 / max(hi - lo, 96);  p' = min(255, (max(p - lo, 0) * scale) >> 8)
// The 96 caps the gain at 2.7x, so flat surfaces (walls, ceilings) are not
// blown up into stripe-like texture (python/robustness study, docs/RESULTS.md).
// Exactly python/cam_golden.autocontrast(). Uploaded photos are used as they
// are (STRETCH_PHOTO = 0), so the PC path stays the published v3 pipeline.
//
// Loading copies the (stretched) 4800 bytes into bcnn_core and into the two
// thumbnail RAMs (UART snapshot, VGA overlay): both show what the network saw.
//
// Bank safety: the bank is latched when its frame is announced. The camera
// side starts overwriting a bank only 8 lines (~0.5 ms) after it starts a new
// frame in it, and that happens at the earliest one frame (37.5 ms) after the
// announcement. Histogram + copy take ~10k clocks (0.2 ms at 50 MHz), started
// at the latest when the current inference ends, and announcements during an
// inference re-latch the newer bank - so a job never sees a bank being written.
//
// Decision (camera frames): margin = score - threshold, averaged over the last
// 2^AVG_LOG2 frames, then the v3 "not sure" band from mem/demo.json:
//   avg >= BAND_HI -> CROSSING,  avg < BAND_LO -> NO CROSSING,  else NOT SURE.
// Switches: plain = margin >= 0 decides (no band); noavg = no averaging.
// No camera result for 1 s -> WAITING, and the average restarts.
//------------------------------------------------------------------------------

module bcnn_engine #(
    parameter CLK_HZ   = 50_000_000,
    parameter BANK     = 4800,
    parameter AVG_LOG2 = 2,
    parameter signed [15:0] BAND_LO = -16'sd31,
    parameter signed [15:0] BAND_HI = 16'sd33,
    parameter STRETCH_K     = 24,          // pixels ignored at each end
    parameter STRETCH_MIN   = 96,          // gain cap: ranges below 96 are stretched 2.7x at most
    parameter STRETCH_PHOTO = 0,           // also stretch photos from the PC
    parameter WEIGHT_FILE = "bcnn_weights.mem",
    parameter THRESH_FILE = "bcnn_thresh.mem"
)(
    input  wire        clk,
    input  wire        rst_n,             // synchronous, active low

    // from the camera / UART domain (asynchronous)
    input  wire        frame_tog_a,       // a camera frame was committed
    input  wire        frame_bank_a,      // ... into this bank (stable with the toggle)
    input  wire [15:0] frame_cnt_a,
    input  wire        inject_tog_a,      // a photo is waiting in bank 2
    input  wire        snap_req_a,        // UART wants a stable snapshot (level)
    input  wire        cam_pause_a,       // PC asked to ignore the camera (level)

    // switches (asynchronous)
    input  wire        sw_plain_a,
    input  wire        sw_noavg_a,
    input  wire        sw_raw_a,          // 1: no auto-contrast

    // frame-buffer read port (clk)
    output reg  [13:0] fb_raddr,
    input  wire [7:0]  fb_rdata,

    // thumbnail write port (clk) - image the network saw (= the core's image port)
    output wire        th_we,
    output wire [12:0] th_addr,
    output wire [7:0]  th_data,

    // back to the UART domain
    output reg         snap_ack,          // level: results + thumbnail held still
    output reg         inject_done_tog,
    output reg         inj_detect,
    output reg  [15:0] inj_score,
    output reg  signed [15:0] inj_thr,

    // result bundle (stable while snap_ack, and between res_tog flips)
    output reg         res_tog,
    output reg  [1:0]  res_state,         // 0 none, 1 not sure, 2 crossing, 3 waiting
    output reg         res_src,           // 0 camera, 1 uploaded photo
    output reg  [15:0] res_score,
    output reg  signed [15:0] res_thr,
    output reg  signed [15:0] res_margin,
    output reg  signed [15:0] res_avg,
    output reg  [15:0] res_frame,         // camera frame number of the image
    output reg  [15:0] res_infer,         // inference counter
    output reg  [7:0]  res_fps,           // camera inferences in the last second
    output reg  [15:0] res_missed,        // camera frames skipped while busy
    output reg         res_paused,
    output reg         res_stretched,     // auto-contrast was applied to this image
    output reg  [7:0]  res_lo,            // ... with these levels
    output reg  [7:0]  res_hi,

    output wire        core_busy
);
    localparam signed [15:0] ZERO = 16'sd0;

    //--------------------------------------------------------------------------
    // Synchronisers
    //--------------------------------------------------------------------------
    wire frame_pulse, inject_pulse, snap_req, cam_pause, sw_plain, sw_noavg, sw_raw;
    cdc_toggle u_s_frame  (.clk(clk), .tog(frame_tog_a),  .pulse(frame_pulse));
    cdc_toggle u_s_inject (.clk(clk), .tog(inject_tog_a), .pulse(inject_pulse));
    cdc_bit    u_s_snap   (.clk(clk), .d(snap_req_a),     .q(snap_req));
    cdc_bit    u_s_pause  (.clk(clk), .d(cam_pause_a),    .q(cam_pause));
    cdc_bit    u_s_plain  (.clk(clk), .d(sw_plain_a),     .q(sw_plain));
    cdc_bit    u_s_noavg  (.clk(clk), .d(sw_noavg_a),     .q(sw_noavg));
    cdc_bit    u_s_raw    (.clk(clk), .d(sw_raw_a),       .q(sw_raw));

    //--------------------------------------------------------------------------
    // BCNN core
    //--------------------------------------------------------------------------
    reg         img_we;
    reg  [12:0] img_waddr;
    reg  [7:0]  img_wdata;
    reg         core_start;
    wire        core_done, core_detect;
    wire [15:0] core_score;
    wire signed [15:0] core_thr;

    assign th_we   = img_we;
    assign th_addr = img_waddr;
    assign th_data = img_wdata;

    bcnn_core #(.WEIGHT_FILE(WEIGHT_FILE), .THRESH_FILE(THRESH_FILE)) u_core (
        .clk(clk), .rst_n(rst_n),
        .img_we(img_we), .img_waddr(img_waddr), .img_wdata(img_wdata),
        .start(core_start), .busy(core_busy), .done(core_done),
        .detect(core_detect), .score(core_score), .threshold(core_thr));

    //--------------------------------------------------------------------------
    // Pending work
    //--------------------------------------------------------------------------
    reg        frame_pend, inj_pend, fresh;
    reg        pend_bank;
    reg [15:0] pend_frame;

    //--------------------------------------------------------------------------
    // Margin history for the moving average
    //--------------------------------------------------------------------------
    localparam AVG_N = 1 << AVG_LOG2;
    reg signed [15:0] mhist [0:AVG_N-1];
    reg [AVG_LOG2-1:0] hptr;
    reg signed [19:0] hsum;
    reg               restart_avg;

    //--------------------------------------------------------------------------
    // Pixel histogram for auto-contrast (distributed RAM, read asynchronously:
    // an increment reads and writes the same bin in one clock)
    //--------------------------------------------------------------------------
    reg [12:0] phist [0:255];
    reg [7:0]  hv;                 // bin being cleared / scanned
    reg [12:0] cum;
    reg [7:0]  lo, hi;
    reg [15:0] div_rem, quot;
    reg [7:0]  divisor;
    reg [4:0]  div_i;
    reg [11:0] scale;
    reg        do_stretch;
    wire [12:0] cum_next = cum + phist[hv];
    localparam [15:0] DIVIDEND = 16'hFF00;            // 255 * 256
    wire [16:0] div_try = {div_rem, DIVIDEND[div_i - 1'b1]};

    //--------------------------------------------------------------------------
    // Timers: 1 s window for fps and for "camera gone"
    //--------------------------------------------------------------------------
    reg [26:0] sec_cnt;
    reg [7:0]  fps_cnt, fps_last;
    reg [15:0] missed_cnt;
    reg [27:0] idle_cnt;          // clocks since the last camera result
    wire       sec_tick = (sec_cnt == CLK_HZ - 1);
    wire       cam_gone = (idle_cnt >= CLK_HZ);

    //--------------------------------------------------------------------------
    // Main FSM
    //--------------------------------------------------------------------------
    localparam S_IDLE = 4'd0, S_HCLR = 4'd1, S_SCAN = 4'd2, S_LO = 4'd3, S_HI = 4'd4,
               S_DIV = 4'd5, S_LOAD = 4'd6, S_START = 4'd7, S_RUN = 4'd8,
               S_POST = 4'd9, S_POST2 = 4'd10, S_SNAP = 4'd11;
    reg [3:0]  state;
    reg        job_src;           // 0 camera, 1 photo
    reg [15:0] job_frame;
    reg [13:0] base;
    reg [12:0] rd_i;              // next pixel to address
    // read / transform pipeline: address (1) -> BRAM data (2) -> p - lo (3)
    // -> x scale (4) -> clamp, write (5)
    reg        v1, v2, v3, v4;
    reg [12:0] i1, i2, i3, i4;
    reg [7:0]  d3;
    reg [19:0] p4;

    reg signed [15:0] margin_r;
    reg signed [19:0] sum_new;
    integer k;

    function [1:0] classify;
        input signed [15:0] v;
        input               plain;
        begin
            if (plain)              classify = (v >= ZERO)    ? 2'd2 : 2'd0;
            else if (v >= BAND_HI)  classify = 2'd2;
            else if (v <  BAND_LO)  classify = 2'd0;
            else                    classify = 2'd1;
        end
    endfunction

    wire scanning = (state == S_SCAN);
    wire pipe_busy = v1 | v2 | v3 | v4 | img_we;

    // histogram update (separate block: a memory written with a variable index)
    always @(posedge clk) begin
        if (state == S_HCLR)
            phist[hv] <= 13'd0;
        else if (scanning && v2)
            phist[fb_rdata] <= phist[fb_rdata] + 1'b1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            fb_raddr <= 0;
            img_we <= 0; img_waddr <= 0; img_wdata <= 0; core_start <= 0;
            frame_pend <= 0; inj_pend <= 0; fresh <= 0; pend_bank <= 0; pend_frame <= 0;
            snap_ack <= 0; inject_done_tog <= 0; inj_detect <= 0; inj_score <= 0; inj_thr <= 0;
            res_tog <= 0; res_state <= 2'd3; res_src <= 0; res_score <= 0; res_thr <= 0;
            res_margin <= 0; res_avg <= 0; res_frame <= 0; res_infer <= 0; res_fps <= 0;
            res_missed <= 0; res_paused <= 0; res_stretched <= 0; res_lo <= 0; res_hi <= 0;
            job_src <= 0; job_frame <= 0; base <= 0; rd_i <= 0;
            v1 <= 0; v2 <= 0; v3 <= 0; v4 <= 0; i1 <= 0; i2 <= 0; i3 <= 0; i4 <= 0; d3 <= 0; p4 <= 0;
            hv <= 0; cum <= 0; lo <= 0; hi <= 0; div_rem <= 0; quot <= 0; divisor <= 0; div_i <= 0;
            scale <= 0; do_stretch <= 0;
            hptr <= 0; hsum <= 0; restart_avg <= 1; margin_r <= 0; sum_new <= 0;
            for (k = 0; k < AVG_N; k = k + 1) mhist[k] <= 0;
            sec_cnt <= 0; fps_cnt <= 0; fps_last <= 0; missed_cnt <= 0; idle_cnt <= 0;
        end else begin
            img_we     <= 0;
            core_start <= 0;
            res_paused <= cam_pause;

            // announcements
            if (frame_pulse) begin
                if (frame_pend) missed_cnt <= missed_cnt + 1'b1;
                frame_pend <= 1;
                pend_bank  <= frame_bank_a;
                pend_frame <= frame_cnt_a;
            end
            if (inject_pulse) inj_pend <= 1;

            // timers
            sec_cnt <= sec_tick ? 27'd0 : sec_cnt + 1'b1;
            if (sec_tick) begin
                fps_last <= fps_cnt;
                fps_cnt  <= 0;
            end
            // counters reach the result bundle only while it is not being read
            if (state != S_SNAP) begin
                res_fps    <= fps_last;
                res_missed <= missed_cnt;
            end
            if (!cam_gone) idle_cnt <= idle_cnt + 1'b1;
            if (cam_gone && !cam_pause && res_state != 2'd3 && !res_src && state == S_IDLE) begin
                res_state   <= 2'd3;      // camera stopped delivering frames
                restart_avg <= 1;
                res_tog     <= ~res_tog;
            end

            // read / transform pipeline
            v1 <= 0;
            v2 <= v1;  i2 <= i1;
            v3 <= v2 && !scanning;  i3 <= i2;
            d3 <= !do_stretch ? fb_rdata : (fb_rdata > lo ? fb_rdata - lo : 8'd0);
            v4 <= v3;  i4 <= i3;
            p4 <= do_stretch ? d3 * scale : {4'd0, d3, 8'd0};
            if (v4) begin
                img_we    <= 1;
                img_waddr <= i4;
                img_wdata <= (p4[19:8] > 12'd255) ? 8'd255 : p4[15:8];
            end

            case (state)
                S_IDLE: begin
                    if (inj_pend) begin
                        inj_pend   <= 0;
                        job_src    <= 1;
                        job_frame  <= 0;
                        base       <= 2 * BANK;
                        do_stretch <= (STRETCH_PHOTO != 0) && !sw_raw;
                        hv         <= 0;
                        state      <= ((STRETCH_PHOTO != 0) && !sw_raw) ? S_HCLR : S_LOAD;
                        rd_i       <= 0;
                    end else if (snap_req && (fresh || !frame_pend || cam_pause)) begin
                        snap_ack <= 1;
                        state    <= S_SNAP;
                    end else if (frame_pend && !cam_pause) begin
                        frame_pend <= 0;
                        job_src    <= 0;
                        job_frame  <= pend_frame;
                        base       <= pend_bank ? BANK : 0;
                        do_stretch <= !sw_raw;
                        hv         <= 0;
                        state      <= sw_raw ? S_LOAD : S_HCLR;
                        rd_i       <= 0;
                    end else if (frame_pend && cam_pause) begin
                        frame_pend <= 0;              // paused: drop it
                    end
                end

                // ---- auto-contrast: clear histogram, count, find lo / hi ----
                S_HCLR: begin
                    hv <= hv + 1'b1;
                    if (hv == 8'd255) state <= S_SCAN;
                end

                S_SCAN: begin
                    if (rd_i < BANK) begin
                        fb_raddr <= base + rd_i;
                        v1       <= 1;
                        i1       <= rd_i;
                        rd_i     <= rd_i + 1'b1;
                    end else if (!v1 && !v2) begin
                        hv    <= 0;
                        cum   <= 0;
                        state <= S_LO;
                    end
                end

                S_LO: begin                       // lo: first level with > K pixels at or below
                    if (cum_next > STRETCH_K) begin
                        lo    <= hv;
                        hv    <= 8'd255;
                        cum   <= 0;
                        state <= S_HI;
                    end else begin
                        cum <= cum_next;
                        hv  <= hv + 1'b1;
                    end
                end

                S_HI: begin                       // hi: same from the top
                    if (cum_next > STRETCH_K) begin
                        hi      <= hv;
                        divisor <= (hv - lo < STRETCH_MIN) ? STRETCH_MIN : hv - lo;
                        div_rem <= 0;
                        quot    <= 0;
                        div_i   <= 5'd16;
                        state   <= S_DIV;
                    end else begin
                        cum <= cum_next;
                        hv  <= hv - 1'b1;
                    end
                end

                S_DIV: begin                      // scale = 65280 / divisor, restoring division
                    if (div_i != 0) begin
                        if (div_try >= {9'd0, divisor}) begin
                            div_rem <= div_try - {9'd0, divisor};
                            quot    <= {quot[14:0], 1'b1};
                        end else begin
                            div_rem <= div_try[15:0];
                            quot    <= {quot[14:0], 1'b0};
                        end
                        div_i <= div_i - 1'b1;
                    end else begin
                        scale <= quot[11:0];          // 65280 / 16 = 4080 at most
                        rd_i  <= 0;
                        state <= S_LOAD;
                    end
                end

                // ---- copy (and stretch) into the core and the thumbnails ----
                S_LOAD: begin
                    if (rd_i < BANK) begin
                        fb_raddr <= base + rd_i;
                        v1       <= 1;
                        i1       <= rd_i;
                        rd_i     <= rd_i + 1'b1;
                    end else if (!pipe_busy) begin
                        state <= S_START;             // last pixel written
                    end
                end

                S_START: begin
                    core_start <= 1;
                    state      <= S_RUN;
                end

                S_RUN: begin
                    if (core_done) begin
                        margin_r <= $signed(core_score) - core_thr;
                        state    <= S_POST;
                    end
                end

                S_POST: begin
                    res_score     <= core_score;
                    res_thr       <= core_thr;
                    res_margin    <= margin_r;
                    res_frame     <= job_frame;
                    res_infer     <= res_infer + 1'b1;
                    res_src       <= job_src;
                    res_stretched <= do_stretch;
                    res_lo        <= do_stretch ? lo : 8'd0;
                    res_hi        <= do_stretch ? hi : 8'd255;
                    fresh         <= 1;
                    if (job_src) begin
                        inj_detect <= core_detect;
                        inj_score  <= core_score;
                        inj_thr    <= core_thr;
                        inject_done_tog <= ~inject_done_tog;
                        res_avg    <= margin_r;
                        res_state  <= classify(margin_r, sw_plain);
                        state      <= S_POST2;
                    end else begin
                        idle_cnt <= 0;
                        fps_cnt  <= fps_cnt + 1'b1;
                        if (restart_avg) begin
                            for (k = 0; k < AVG_N; k = k + 1) mhist[k] <= margin_r;
                            hsum        <= $signed(margin_r) <<< AVG_LOG2;
                            sum_new     <= $signed(margin_r) <<< AVG_LOG2;
                            restart_avg <= 0;
                        end else begin
                            mhist[hptr] <= margin_r;
                            hsum        <= hsum + margin_r - mhist[hptr];
                            sum_new     <= hsum + margin_r - mhist[hptr];
                        end
                        hptr  <= hptr + 1'b1;
                        state <= S_POST2;
                    end
                end

                S_POST2: begin
                    if (!job_src) begin
                        res_avg   <= sw_noavg ? margin_r : $signed(sum_new >>> AVG_LOG2);
                        res_state <= classify(sw_noavg ? margin_r : $signed(sum_new >>> AVG_LOG2),
                                              sw_plain);
                    end
                    res_tog <= ~res_tog;
                    state   <= S_IDLE;
                end

                S_SNAP: begin
                    if (!snap_req) begin
                        snap_ack <= 0;
                        fresh    <= 0;
                        state    <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
