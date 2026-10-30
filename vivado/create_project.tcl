# create_project.tcl - Vivado GUI project for the zebra-crossing camera.
#
#   Vivado GUI: Tools -> Run Tcl Script... -> vivado/create_project.tcl
#   or:         vivado -source vivado/create_project.tcl
#
# Creates vivado/proj/zebracam.xpr with every source, the ROM / font files,
# the include path for bcnn_config.vh, the SDRAM_IOB define and both XDC files:
# the same design as bitstream/zebracam.bit (vivado/build.tcl iob 12).
# Then: Run Synthesis -> Run Implementation -> Generate Bitstream -> Open
# Hardware Manager -> Program Device (the bitstream is in
# vivado/proj/zebracam.runs/impl_1/top.bit).
#
# For the PROVEN-SDRAM fallback: remove SDRAM_IOB from Settings -> General ->
# Verilog options -> Defines, and swap sdram_iob.xdc for sdram_loc.xdc.

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set proj $here/proj

create_project zebracam $proj -part xc7a35tftg256-1 -force
set_property target_language Verilog [current_project]

# RTL
add_files -fileset sources_1 [concat \
    [glob $root/rtl/*.v] [glob $root/rtl/io/*.v] [glob $root/rtl/vision/*.v] \
    [glob $root/rtl/bcnn/*.v] [glob $root/rtl/camera/*.v]]

# ROM contents ($readmemh finds project files by name) and the network header
add_files -fileset sources_1 [list \
    $root/mem/bcnn_weights.mem $root/mem/bcnn_thresh.mem $root/mem/font8x16.mem \
    $root/mem/bcnn_config.vh]
set_property file_type {Memory File} [get_files -of_objects [get_filesets sources_1] *.mem]
set_property file_type {Verilog Header} [get_files bcnn_config.vh]
set_property include_dirs [list $root/mem] [get_filesets sources_1]

# same options as the default bitstream
set_property verilog_define {SDRAM_IOB=1} [get_filesets sources_1]
set_property generic {CORE_DIV=12} [get_filesets sources_1]
set_property top top [get_filesets sources_1]

# constraints
add_files -fileset constrs_1 [list $here/top.xdc $here/sdram_iob.xdc]
set_property target_constrs_file $here/top.xdc [get_filesets constrs_1]

update_compile_order -fileset sources_1
puts "=================================================="
puts " project: $proj/zebracam.xpr"
puts " Run Synthesis / Implementation / Generate Bitstream from the Flow Navigator"
puts "=================================================="
