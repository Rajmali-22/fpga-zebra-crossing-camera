`timescale 1ns / 1ps
//------------------------------------------------------------------------------
// clk_rst.v  -  every clock of the design from one MMCM, plus per-domain resets
//
// 50 MHz in (N11), VCO = 50 x 16 = 800 MHz.
//
//   clk_xclk  800 / 37.5 = 21.333 MHz  OV7670 XCLK
//   clk_sys   800 / 6    = 133.33 MHz  camera, SDRAM, UART, preprocessing
//   clk_vga   800 / 32   = 25.000 MHz  VGA 640x480 @ 60 Hz
//   clk_core  800 / CORE_DIV           BCNN engine, LCD, buzzer (16 -> 50 MHz)
//
// The first three are exactly the frequencies the hardware-proven camera
// build ran at: Vivado had turned its three Spartan-6 DCM_SP cores into MMCMs
// with VCO 800 MHz and dividers 37.5 / 6 / 32 (read back from the routed
// checkpoint, and 133.33 MHz matches the 5,333,333 baud measured on the
// board). One native MMCM gives the same clocks with correct timing models.
//
// Feedback goes through a BUFG (ZHOLD compensation) as in the proven build.
//
// Resets: the board switch (M6, active low) resets the MMCM; each domain gets
// "switch up AND MMCM locked", asserted asynchronously, released synchronously.
//------------------------------------------------------------------------------

module clk_rst #(
    parameter integer CORE_DIV = 16
)(
    input  wire clk_in,       // 50 MHz board oscillator
    input  wire rst_n_in,     // board switch, asynchronous, active low

    output wire clk_xclk,
    output wire clk_sys,
    output wire clk_vga,
    output wire clk_core,
    output wire locked,

    output wire rst_n_sys,
    output wire rst_n_vga,
    output wire rst_n_core
);
    wire clkfb_out, clkfb_buf;
    wire xclk_mmcm, sys_mmcm, vga_mmcm, core_mmcm;

    MMCME2_BASE #(
        .BANDWIDTH       ("OPTIMIZED"),
        .CLKIN1_PERIOD   (20.000),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (16.000),
        .CLKFBOUT_PHASE  (0.000),
        .CLKOUT0_DIVIDE_F(37.500),
        .CLKOUT1_DIVIDE  (6),
        .CLKOUT2_DIVIDE  (32),
        .CLKOUT3_DIVIDE  (CORE_DIV),
        .STARTUP_WAIT    ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clkfb_buf),
        .CLKFBOUT (clkfb_out),
        .CLKFBOUTB(),
        .CLKOUT0  (xclk_mmcm),
        .CLKOUT0B (),
        .CLKOUT1  (sys_mmcm),
        .CLKOUT1B (),
        .CLKOUT2  (vga_mmcm),
        .CLKOUT2B (),
        .CLKOUT3  (core_mmcm),
        .CLKOUT3B (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (~rst_n_in)
    );

    BUFG u_bufg_fb   (.I(clkfb_out), .O(clkfb_buf));
    BUFG u_bufg_xclk (.I(xclk_mmcm), .O(clk_xclk));
    BUFG u_bufg_sys  (.I(sys_mmcm),  .O(clk_sys));
    BUFG u_bufg_vga  (.I(vga_mmcm),  .O(clk_vga));
    BUFG u_bufg_core (.I(core_mmcm), .O(clk_core));

    wire arst_n = rst_n_in & locked;

    reset_sync u_rs_sys  (.clk(clk_sys),  .arst_n(arst_n), .rst_n(rst_n_sys));
    reset_sync u_rs_vga  (.clk(clk_vga),  .arst_n(arst_n), .rst_n(rst_n_vga));
    reset_sync u_rs_core (.clk(clk_core), .arst_n(arst_n), .rst_n(rst_n_core));
endmodule
