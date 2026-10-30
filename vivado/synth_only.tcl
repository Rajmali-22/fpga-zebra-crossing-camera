set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set out  $here/synth_check
file mkdir $out
foreach f {bcnn_weights.mem bcnn_thresh.mem font8x16.mem bcnn_config.vh} { file copy -force $root/mem/$f $out }
cd $out
read_verilog [concat [glob $root/rtl/*.v] [glob $root/rtl/io/*.v] [glob $root/rtl/vision/*.v] [glob $root/rtl/bcnn/*.v] [glob $root/rtl/camera/*.v]]
read_xdc $here/top.xdc
read_xdc $here/sdram_iob.xdc
synth_design -top top -part xc7a35tftg256-1 -include_dirs $out -verilog_define SDRAM_IOB=1
report_utilization -file $out/util.rpt
puts "SYNTH_DONE"
