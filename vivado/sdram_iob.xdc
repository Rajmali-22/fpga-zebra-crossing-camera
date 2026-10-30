## SDRAM I/O registers packed into the IOBs (default build).
## With sdram_clk = inverted clk_sys this centres the SDRAM's sampling point in
## the output data eye; the timing report shows the margins.
set_property IOB TRUE [get_ports {sdram_addr[*] sdram_ba[*] sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_dq[*]}]
