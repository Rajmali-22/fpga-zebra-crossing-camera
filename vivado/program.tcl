# program.tcl - load a bitstream into the EDGE Artix-7 over JTAG (USB cable).
#
#   vivado -mode batch -source vivado/program.tcl -tclargs bitstream/zebracam.bit
#   (or just double-click program.bat)
#
# The FPGA keeps the design until power is removed. For a permanent design,
# write bitstream/zebracam.bin into the board's SPI flash (README, "Flash").

set bit [expr {[llength $argv] > 0 ? [lindex $argv 0] : "bitstream/zebracam.bit"}]
set bit [file normalize $bit]
if {![file exists $bit]} { puts "ERROR: $bit not found"; exit 1 }

open_hw_manager
connect_hw_server -allow_non_jtag
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    puts "ERROR: no JTAG cable found - is the board powered and the USB cable connected?"
    exit 1
}
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices -quiet xc7a35t*] 0]
if {$dev eq ""} {
    puts "ERROR: no xc7a35t on the JTAG chain (found: [get_hw_devices])"
    exit 1
}
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "=================================================="
puts " programmed $bit"
puts " DONE = [get_property REGISTER.IR.BIT5_DONE $dev]"
puts " next: python host/zebracam.py auto selftest"
puts "=================================================="
close_hw_target
disconnect_hw_server
close_hw_manager
