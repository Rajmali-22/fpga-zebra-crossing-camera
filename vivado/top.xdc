##-----------------------------------------------------------------------------
## top.xdc - Zebra-crossing camera, EDGE Artix-7 (XC7A35T-1FTG256C)
## Pins from the board's master XDC and the hardware-proven camera build.
##-----------------------------------------------------------------------------

## 50 MHz oscillator
set_property -dict {PACKAGE_PIN N11 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk_pin -waveform {0.000 10.000} [get_ports clk]
## N11 reaches the MMCM through general routing (as in the proven build)
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins u_clk/u_mmcm/CLKIN1]]

## Reset switch M6 (UP = run) and the other slide switches
set_property -dict {PACKAGE_PIN M6 IOSTANDARD LVCMOS33} [get_ports rst_n]
set_property -dict {PACKAGE_PIN L5 IOSTANDARD LVCMOS33} [get_ports {key[0]}]
set_property -dict {PACKAGE_PIN L4 IOSTANDARD LVCMOS33} [get_ports {key[1]}]
set_property -dict {PACKAGE_PIN M4 IOSTANDARD LVCMOS33} [get_ports {key[2]}]
set_property -dict {PACKAGE_PIN M2 IOSTANDARD LVCMOS33} [get_ports {key[3]}]
set_property -dict {PACKAGE_PIN M1 IOSTANDARD LVCMOS33} [get_ports sw_plain]
set_property -dict {PACKAGE_PIN N3 IOSTANDARD LVCMOS33} [get_ports sw_noavg]
set_property -dict {PACKAGE_PIN N2 IOSTANDARD LVCMOS33} [get_ports sw_mute]
set_property -dict {PACKAGE_PIN N1 IOSTANDARD LVCMOS33} [get_ports sw_ovl_off]
set_property -dict {PACKAGE_PIN P1 IOSTANDARD LVCMOS33} [get_ports sw_raw]

## Centre push-button: photo to the PC (active high, pull-down)
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports btn_capture]

## OV7670 camera
set_property -dict {PACKAGE_PIN R15 IOSTANDARD LVCMOS33} [get_ports cmos_pclk]
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports cmos_href]
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33} [get_ports cmos_vsync]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports {cmos_db[7]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33} [get_ports {cmos_db[6]}]
set_property -dict {PACKAGE_PIN N13 IOSTANDARD LVCMOS33} [get_ports {cmos_db[5]}]
set_property -dict {PACKAGE_PIN P13 IOSTANDARD LVCMOS33} [get_ports {cmos_db[4]}]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports {cmos_db[3]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {cmos_db[2]}]
set_property -dict {PACKAGE_PIN P10 IOSTANDARD LVCMOS33} [get_ports {cmos_db[1]}]
set_property -dict {PACKAGE_PIN P11 IOSTANDARD LVCMOS33} [get_ports {cmos_db[0]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports cmos_sda]
set_property -dict {PACKAGE_PIN M16 IOSTANDARD LVCMOS33} [get_ports cmos_scl]
set_property -dict {PACKAGE_PIN R12 IOSTANDARD LVCMOS33} [get_ports cmos_rst_n]
set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVCMOS33} [get_ports cmos_pwdn]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} [get_ports cmos_xclk]

## 256 Mb SDRAM
set_property -dict {PACKAGE_PIN D8  IOSTANDARD LVCMOS33} [get_ports {sdram_dq[0]}]
set_property -dict {PACKAGE_PIN C8  IOSTANDARD LVCMOS33} [get_ports {sdram_dq[1]}]
set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS33} [get_ports {sdram_dq[2]}]
set_property -dict {PACKAGE_PIN A9  IOSTANDARD LVCMOS33} [get_ports {sdram_dq[3]}]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS33} [get_ports {sdram_dq[4]}]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[5]}]
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[6]}]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[7]}]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[8]}]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[9]}]
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS33} [get_ports {sdram_dq[10]}]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[11]}]
set_property -dict {PACKAGE_PIN C9  IOSTANDARD LVCMOS33} [get_ports {sdram_dq[12]}]
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[13]}]
set_property -dict {PACKAGE_PIN B12 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[14]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {sdram_dq[15]}]
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS33} [get_ports {sdram_addr[0]}]
set_property -dict {PACKAGE_PIN E11 IOSTANDARD LVCMOS33} [get_ports {sdram_addr[1]}]
set_property -dict {PACKAGE_PIN E13 IOSTANDARD LVCMOS33} [get_ports {sdram_addr[2]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {sdram_addr[3]}]
set_property -dict {PACKAGE_PIN F3  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[4]}]
set_property -dict {PACKAGE_PIN G2  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[5]}]
set_property -dict {PACKAGE_PIN G1  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[6]}]
set_property -dict {PACKAGE_PIN H1  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[7]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[8]}]
set_property -dict {PACKAGE_PIN H2  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[9]}]
set_property -dict {PACKAGE_PIN J4  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[10]}]
set_property -dict {PACKAGE_PIN H4  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[11]}]
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {sdram_addr[12]}]
set_property -dict {PACKAGE_PIN B14 IOSTANDARD LVCMOS33} [get_ports {sdram_ba[0]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports {sdram_ba[1]}]
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33} [get_ports {sdram_dqm[0]}]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports {sdram_dqm[1]}]
set_property -dict {PACKAGE_PIN D13 IOSTANDARD LVCMOS33} [get_ports sdram_clk]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports sdram_cke]
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports sdram_cs_n]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports sdram_we_n]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports sdram_cas_n]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports sdram_ras_n]

## VGA, 12 bit
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports vga_out_hs]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports vga_out_vs]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports {vga_out_r[0]}]
set_property -dict {PACKAGE_PIN F12 IOSTANDARD LVCMOS33} [get_ports {vga_out_r[1]}]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports {vga_out_r[2]}]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports {vga_out_r[3]}]
set_property -dict {PACKAGE_PIN D16 IOSTANDARD LVCMOS33} [get_ports {vga_out_g[0]}]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports {vga_out_g[1]}]
set_property -dict {PACKAGE_PIN E15 IOSTANDARD LVCMOS33} [get_ports {vga_out_g[2]}]
set_property -dict {PACKAGE_PIN H11 IOSTANDARD LVCMOS33} [get_ports {vga_out_g[3]}]
set_property -dict {PACKAGE_PIN G12 IOSTANDARD LVCMOS33} [get_ports {vga_out_b[0]}]
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS33} [get_ports {vga_out_b[1]}]
set_property -dict {PACKAGE_PIN H13 IOSTANDARD LVCMOS33} [get_ports {vga_out_b[2]}]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports {vga_out_b[3]}]

## USB UART (FT2232H, shares the USB cable with JTAG); proven in soc/plain
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports uart_txd]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports uart_rxd]

## 16x2 LCD (R/W is grounded on the board)
set_property -dict {PACKAGE_PIN P3 IOSTANDARD LVCMOS33} [get_ports {lcd_data[7]}]
set_property -dict {PACKAGE_PIN M5 IOSTANDARD LVCMOS33} [get_ports {lcd_data[6]}]
set_property -dict {PACKAGE_PIN N4 IOSTANDARD LVCMOS33} [get_ports {lcd_data[5]}]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports {lcd_data[4]}]
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVCMOS33} [get_ports {lcd_data[3]}]
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33} [get_ports {lcd_data[2]}]
set_property -dict {PACKAGE_PIN T2 IOSTANDARD LVCMOS33} [get_ports {lcd_data[1]}]
set_property -dict {PACKAGE_PIN T4 IOSTANDARD LVCMOS33} [get_ports {lcd_data[0]}]
set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVCMOS33} [get_ports lcd_e]
set_property -dict {PACKAGE_PIN P5 IOSTANDARD LVCMOS33} [get_ports lcd_rs]

## Buzzer (jumper J6 on "Enable")
set_property -dict {PACKAGE_PIN K12 IOSTANDARD LVCMOS33} [get_ports buzzer_out]

## LEDs
set_property -dict {PACKAGE_PIN J3  IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN H3  IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN J1  IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN K1  IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN L3  IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN L2  IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN K3  IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN K2  IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN K5  IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN P6  IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN R7  IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN R6  IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN T5  IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN R5  IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {led[15]}]

##-----------------------------------------------------------------------------
## Timing
##-----------------------------------------------------------------------------
## The MMCM outputs are only connected through BRAMs with one port per clock
## and through 2-flop / toggle handshakes (rtl/io/cdc.v, asyn_fifo gray codes).
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins u_clk/u_mmcm/CLKOUT0]] \
    -group [get_clocks -of_objects [get_pins u_clk/u_mmcm/CLKOUT1]] \
    -group [get_clocks -of_objects [get_pins u_clk/u_mmcm/CLKOUT2]] \
    -group [get_clocks -of_objects [get_pins u_clk/u_mmcm/CLKOUT3]]

## Asynchronous inputs (synchronised inside) and slow outputs
set_false_path -from [get_ports {rst_n key[*] sw_plain sw_noavg sw_mute sw_ovl_off sw_raw btn_capture uart_rxd}]
set_false_path -from [get_ports {cmos_pclk cmos_href cmos_vsync cmos_db[*] cmos_sda cmos_scl}]
set_false_path -to   [get_ports {uart_txd led[*] lcd_data[*] lcd_rs lcd_e buzzer_out}]
set_false_path -to   [get_ports {vga_out_r[*] vga_out_g[*] vga_out_b[*] vga_out_hs vga_out_vs}]
set_false_path -to   [get_ports {cmos_sda cmos_scl cmos_rst_n cmos_pwdn}]

## SDRAM interface. sdram_clk is clk_sys inverted by an ODDR, so the SDRAM
## samples in the middle of the FPGA's output cycle. Numbers: -7 speed grade
## SDR SDRAM (tIS 1.5 ns, tIH 0.8 ns, tAC 5.4 ns at CL3, tOH 2.7 ns).
create_generated_clock -name sdram_clk_out -source [get_pins oddr2_primitive/C] \
    -multiply_by 1 -invert [get_ports sdram_clk]
set SDRAM_OUT [get_ports {sdram_addr[*] sdram_ba[*] sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_dq[*]}]
set_output_delay -clock sdram_clk_out -max  1.5 $SDRAM_OUT
set_output_delay -clock sdram_clk_out -min -0.8 $SDRAM_OUT
set_input_delay  -clock sdram_clk_out -max  5.4 [get_ports {sdram_dq[*]}]
set_input_delay  -clock sdram_clk_out -min  2.7 [get_ports {sdram_dq[*]}]
## read data launched by an SDRAM clock edge is captured two clk_sys edges later
set_multicycle_path -setup 2 -from [get_clocks sdram_clk_out] -to [get_clocks -of_objects [get_pins u_clk/u_mmcm/CLKOUT1]]
set_multicycle_path -hold  1 -from [get_clocks sdram_clk_out] -to [get_clocks -of_objects [get_pins u_clk/u_mmcm/CLKOUT1]]
## sdram_cke and the DQ masks are constants
set_false_path -to [get_ports {sdram_cke sdram_dqm[*]}]

##-----------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
