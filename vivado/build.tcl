# build.tcl - synthesis, implementation, reports and bitstream (non-project).
#
#   vivado -mode batch -source vivado/build.tcl -tclargs <variant> [core_div] [bit]
#
#   variant   iob     SDRAM I/O registers in the IOBs (default, timing-centred)
#             proven  SDRAM I/O registers on the slice sites of the
#                     hardware-proven camera build (vivado/sdram_loc.xdc)
#   core_div  800 MHz / core_div = BCNN clock (12 -> 66.7 MHz default, 16 -> 50 MHz)
#   bit       write the bitstream
#
# Output: vivado/build_<variant>_<core_div>/ (reports, checkpoint, top.bit)

set variant  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "iob"}]
set core_div [expr {[llength $argv] > 1 ? [lindex $argv 1] : 12}]
set do_bit   [expr {[llength $argv] > 2 && [lindex $argv 2] eq "bit"}]

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set out  $here/build_${variant}_${core_div}
set part xc7a35tftg256-1
file mkdir $out

# $readmemh finds the ROM images in the working directory
foreach f {bcnn_weights.mem bcnn_thresh.mem font8x16.mem bcnn_config.vh} {
    file copy -force $root/mem/$f $out
}
cd $out

set srcs [concat [glob $root/rtl/*.v] [glob $root/rtl/io/*.v] [glob $root/rtl/vision/*.v] \
                 [glob $root/rtl/bcnn/*.v] [glob $root/rtl/camera/*.v]]
read_verilog $srcs
read_xdc $here/top.xdc
if {$variant eq "iob"} {
    read_xdc $here/sdram_iob.xdc
} else {
    read_xdc $here/sdram_loc.xdc
}

set proven [expr {$variant eq "proven" ? 1 : 0}]
if {$variant eq "iob"} {
    synth_design -top top -part $part -include_dirs $out -verilog_define SDRAM_IOB=1 \
        -generic CORE_DIV=$core_div -generic PROVEN_SDRAM=$proven
} else {
    synth_design -top top -part $part -include_dirs $out \
        -generic CORE_DIV=$core_div -generic PROVEN_SDRAM=$proven
}
report_utilization -file $out/utilization_synth.rpt
opt_design
place_design
phys_opt_design
route_design

report_utilization                -file $out/utilization.rpt
report_utilization -hierarchical  -file $out/utilization_hier.rpt
report_timing_summary -max_paths 10 -file $out/timing.rpt
report_clock_interaction          -file $out/clock_interaction.rpt
report_clocks                     -file $out/clocks.rpt
report_drc                        -file $out/drc.rpt
report_methodology                -file $out/methodology.rpt
report_cdc                        -file $out/cdc.rpt
report_power                      -file $out/power.rpt
report_io                         -file $out/io.rpt
report_timing -from [get_ports {sdram_dq[*]}] -max_paths 40 -nworst 1 -file $out/sdram_in.rpt
report_timing -to [get_ports {sdram_*}] -max_paths 60 -nworst 1 -file $out/sdram_out.rpt

# SDRAM pad-to-register delays, same form as docs/sdram_delays_proven.txt
set g [open $out/sdram_delays.txt w]
foreach p [get_ports {sdram_addr[*] sdram_ba[*] sdram_dq[*] sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_clk}] {
    set dir [get_property DIRECTION $p]
    if {$dir ne "IN"} { foreach t [get_timing_paths -quiet -to $p -max_paths 1 -delay_type max -unique_pins] {
        puts $g "OUT $p max [get_property DATAPATH_DELAY $t] from [get_property STARTPOINT_PIN $t]" } }
    if {$dir ne "OUT"} { foreach t [get_timing_paths -quiet -from $p -max_paths 1 -delay_type max] {
        puts $g "IN  $p max [get_property DATAPATH_DELAY $t] to [get_property ENDPOINT_PIN $t]" } }
}
close $g

# which SDRAM registers ended up in IOBs
set g [open $out/sdram_iob_packing.txt w]
foreach c [get_cells -hier -filter {IOB == TRUE}] { puts $g "$c [get_property SITE_TYPE [get_sites -of $c]]" }
foreach c [get_cells -quiet -hier -filter {NAME =~ m1/m0/* && IS_SEQUENTIAL}] {
    set st [get_property SITE_TYPE [get_sites -quiet -of $c]]
    if {[string match "*LOGIC*" $st]} { puts $g "PACKED $c $st" }
}
close $g

write_checkpoint -force $out/top_routed.dcp

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "=================================================="
puts " variant $variant, core clock 800/$core_div MHz"
puts " WNS (setup) $wns ns   WHS (hold) $whs ns"
puts " reports in $out"
puts "=================================================="

if {$do_bit} {
    write_bitstream -force -bin_file $out/top.bit
}
