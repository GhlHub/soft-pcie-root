if {[llength $argv]!=2} {error "Supply fresh output directory and packaged IP repository"}
set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Use a fresh build directory"}
file mkdir $out
exec python3 [file join $root scripts host_sources.py] capture [file join $out sources.json]
create_project zcu104_soft_pcie [file join $out project] -part xczu7ev-ffvc1156-2-e
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
set ip_repo [file normalize [lindex $argv 1]]
if {![file isfile [file join $ip_repo component.xml]]} {error "Missing packaged component.xml"}
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog
create_bd_design system
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} [get_bd_cells ps]
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
 CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} CONFIG.PSU__FPGA_PL0_ENABLE {1} \
 CONFIG.PSU__USE__S_AXI_GP0 {0} CONFIG.PSU__USE__S_AXI_GP1 {0} CONFIG.PSU__USE__S_AXI_GP2 {1} CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} CONFIG.PSU__USE__S_AXI_GP3 {0} \
 CONFIG.PSU__USE__S_AXI_GP4 {0} CONFIG.PSU__USE__S_AXI_GP5 {0} CONFIG.PSU__USE__S_AXI_GP6 {0}] [get_bd_cells ps]
create_bd_cell -type ip -vlnv soft-pcie.org:user:soft_pcie_root:1.1 pcie
set_property CONFIG.ENABLE_GEN3 false [get_bd_cells pcie]
# Keep the board's stock 100 MHz PL0 initialization; derive management50.
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz management_clock
set_property -dict [list CONFIG.PRIM_IN_FREQ {100} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50} CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {125} CONFIG.RESET_TYPE {ACTIVE_LOW}] [get_bd_cells management_clock]
connect_bd_net [get_bd_pins management_clock/clk_out2] [get_bd_pins pcie/host_clk_i]
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins management_clock/clk_in1]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins management_clock/resetn]
connect_bd_net [get_bd_pins management_clock/clk_out1] [get_bd_pins pcie/aclk] [get_bd_pins ps/maxihpm0_fpd_aclk]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset reset
connect_bd_net [get_bd_pins management_clock/clk_out1] [get_bd_pins reset/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins reset/ext_reset_in]
connect_bd_net [get_bd_pins management_clock/locked] [get_bd_pins reset/dcm_locked]
connect_bd_net [get_bd_pins reset/peripheral_aresetn] [get_bd_pins pcie/aresetn]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/ps/M_AXI_HPM0_FPD" Slave "/pcie/S_AXI" Clk_master "/management_clock/clk_out1 (50 MHz)" Clk_slave "/management_clock/clk_out1 (50 MHz)" Clk_xbar "Auto" intc_ip "New AXI Interconnect"} [get_bd_intf_pins pcie/S_AXI]
# BAR/control slave uses core125. AXI automation inserts native clock/width
# conversion from PS HPM0/management50; HP0 remains core125 and noncoherent.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/ps/M_AXI_HPM0_FPD" Slave "/pcie/S_MEM" Clk_master "/management_clock/clk_out1 (50 MHz)" Clk_slave "/pcie/core_clk_o (125 MHz)" Clk_xbar "/management_clock/clk_out1 (50 MHz)" intc_ip "Auto"} [get_bd_intf_pins pcie/S_MEM]
connect_bd_net [get_bd_pins pcie/core_clk_o] [get_bd_pins ps/saxihp0_fpd_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/pcie/M_DDR" Slave "/ps/S_AXI_HP0_FPD" Clk_master "/pcie/core_clk_o (125 MHz)" Clk_slave "/pcie/core_clk_o (125 MHz)" Clk_xbar "/pcie/core_clk_o (125 MHz)" intc_ip "New AXI Interconnect"} [get_bd_intf_pins ps/S_AXI_HP0_FPD]
connect_bd_net [get_bd_pins pcie/irq_o] [get_bd_pins ps/pl_ps_irq0]
foreach name {refclk_p_i refclk_n_i rx_p_i rx_n_i} {
 create_bd_port -dir I $name
 connect_bd_net [get_bd_ports $name] [get_bd_pins pcie/$name]
}
foreach name {tx_p_o tx_n_o perst_a_o disable_ssd2_power_o} {
 create_bd_port -dir O $name
 connect_bd_net [get_bd_ports $name] [get_bd_pins pcie/$name]
}
assign_bd_address -offset 0xA0000000 -range 4K -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs pcie/S_AXI/reg0] -force
assign_bd_address -offset 0xA2000000 -range 32M -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs pcie/S_MEM/reg0] -force
assign_bd_address -offset 0x00000000 -range 2G -target_address_space [get_bd_addr_spaces pcie/M_DDR] [get_bd_addr_segs ps/SAXIGP2/HP0_DDR_LOW] -force
validate_bd_design
if {[get_property CONFIG.DATA_WIDTH [get_bd_intf_pins pcie/M_DDR]]!=64} {error "DDR bridge AXI must be64-bit"}
if {[get_property CONFIG.FREQ_HZ [get_bd_intf_pins pcie/M_DDR]]!=125000000} {error "DDR bridge AXI must run at125MHz"}
if {[get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells reset]]!=0} {error "PS reset must be active low"}
foreach property {NUM_READ_OUTSTANDING NUM_WRITE_OUTSTANDING} {
 if {[get_property CONFIG.$property [get_bd_intf_pins pcie/M_DDR]]!=2} {error "DDR master must advertise two outstanding bursts: $property"}
}
save_bd_design
set bd [get_files system.bd]
make_wrapper -files $bd -top
add_files [file join [file dirname $bd] hdl system_wrapper.v]
read_xdc [file join $root examples zcu104 constraints zcu104_fmc.xdc]
add_files -fileset constrs_1 [file join $root examples zcu104 constraints zcu104_cdc.tcl]
set_property FILE_TYPE TCL [get_files zcu104_cdc.tcl]
set_property PROCESSING_ORDER LATE [get_files zcu104_cdc.tcl]
set_property top system_wrapper [current_fileset]
generate_target all $bd
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
open_run synth_1
exec python3 [file join $root scripts host_sources.py] check [file join $out sources.json]
if {[llength [get_cells -hier -quiet -filter {REF_NAME =~ PCIE*}]]} {error "Soft test image contains PCIe hard macro"}
if {[llength [get_cells -hier -quiet -filter {REF_NAME == GTHE4_CHANNEL}]]!=1} {error "Expected one GTH"}
report_utilization -file [file join $out synth_utilization.rpt]
report_cdc -details -file [file join $out synth_cdc.rpt]
write_checkpoint [file join $out synthesized.dcp]
source [file join $root examples zcu104 check_structure.tcl]
set cdc_file [open [file join $out synth_cdc.rpt] r]
set cdc_check [read $cdc_file]
close $cdc_file
if {[regexp -line {^[[:space:]]*CDC-[0-9]+[[:space:]]+Critical[[:space:]]+[1-9]} $cdc_check]} {error "Unwaived critical synthesized CDC; image withheld"}
launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
exec python3 [file join $root scripts host_sources.py] check [file join $out sources.json]
report_timing_summary -file [file join $out timing.rpt]
report_utilization -file [file join $out utilization.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_drc -file [file join $out drc.rpt]
report_route_status -file [file join $out route.rpt]
report_bus_skew -file [file join $out bus_skew.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]
write_checkpoint [file join $out routed.dcp]
foreach type {max min} {
 set path [get_timing_paths -delay_type $type -max_paths 1]
 if {![llength $path] || [get_property SLACK $path]<0} {error "Routed $type timing failed; image withheld"}
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {error "DRC failed; image withheld"}
set skew [report_bus_skew -return_string]
if {[regexp {Slack \(VIOLATED\)} $skew]} {error "Bus skew failed; image withheld"}
source [file join $root examples zcu104 check_structure.tcl]
set cdc_file [open [file join $out cdc.rpt] r]
set cdc_check [read $cdc_file]
close $cdc_file
if {[regexp -line {^[[:space:]]*CDC-[0-9]+[[:space:]]+Critical[[:space:]]+[1-9]} $cdc_check]} {error "Unwaived critical CDC; image withheld"}
write_bitstream -force [file join $out system.bit]
write_hw_platform -fixed -force -file [file join $out system.xsa]
