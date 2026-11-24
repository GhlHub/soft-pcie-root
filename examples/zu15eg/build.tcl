# SPDX-License-Identifier: Apache-2.0
if {[llength $argv] != 4} {
 error "Supply fresh output directory, packaged IP repository, adapter (op063-a, dp01-passive or dp04-passive), and backend (legacy, gen3, gen1-x2, gen2-x2 or gen3-x2)"
}
set board_dir [file dirname [file normalize [info script]]]
set root [file normalize [file join $board_dir ../..]]
set out [file normalize [lindex $argv 0]]
set ip_repo [file normalize [lindex $argv 1]]
lassign [lrange $argv 2 end] adapter backend
if {$adapter ni {op063-a dp01-passive dp04-passive}} {error "Unsupported adapter profile: $adapter"}
if {$backend ni {legacy gen3 gen1-x2 gen2-x2 gen3-x2}} {error "Unsupported backend: $backend"}
set dual [expr {$adapter eq "dp04-passive"}]
if {[file exists $out]} {error "Use a fresh build directory"}
set part xczu15eg-ffvb1156-2-i
set link_width [expr {$backend in {gen1-x2 gen2-x2 gen3-x2} ? 2 : 1}]
set x2_stage [expr {$link_width == 2}]
set package_dir [file dirname $ip_repo]
set placement_file [file join $package_dir board-placed-gth.txt]
set full_ddr 0
if {$dual != [file isfile $placement_file]} {
 error "dp04-passive and a dual-root IP package must be used together"
}
if {$dual} {
 set input [open $placement_file r]
 set placement_profile [string trim [read $input]]
 close $input
 set expected_profile [expr {$backend eq "legacy" ? "dual-x1" : "dual-$backend"}]
 if {$backend eq "gen3-x2" && $placement_profile eq "dual-gen3-x2-full-ddr"} {
  set full_ddr 1
 } elseif {$placement_profile ne $expected_profile} {
  error "Expected the $expected_profile IP package"
 }
}
set target_file [open [file join $package_dir target-part.txt] r]
set package_part [string trim [read $target_file]]
close $target_file
if {$package_part ne $part} {error "Packaged PHY targets $package_part; expected $part"}
set width_file [file join $package_dir native-width.txt]
if {[file isfile $width_file]} {
 set input [open $width_file r]
 set package_width [string trim [read $input]]
 close $input
} else {set package_width 1}
set catalog [expr {$package_width eq {1 2}}]
if {$link_width ni $package_width} {error "Package provides lane widths $package_width; expected $link_width"}
if {$catalog && $backend eq "gen1-x2"} {error "Use gen2-x2 for the four-mode catalog or the fixed Gen1 x2 package"}
set source_check [list python3 [file join $root scripts host_sources.py]]
exec {*}$source_check check [file join $package_dir sources.json]
file mkdir $out
exec {*}$source_check capture [file join $out sources.json] --board zu15eg
set enable_gen3 [expr {$backend ne "legacy"}]
set check_structure [expr {$enable_gen3 ?
 [file join $root experiments gen3 check_host_structure.tcl] :
 [file join $root examples zcu104 check_structure.tcl]}]
set cdc_script [file join $root examples zcu104 constraints zcu104_cdc.tcl]
if {$dual} {
 set cdc_script [file join $board_dir constraints zu15eg_dual_cdc.tcl]
 set check_structure [file join $board_dir check_dual_structure.tcl]
}
create_project zu15eg_soft_pcie [file join $out project] -part $part
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
if {![file isfile [file join $ip_repo component.xml]]} {error "Missing packaged component.xml"}
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog
create_bd_design system
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps
source [file join $board_dir ps_ddr4.tcl]
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
 CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} CONFIG.PSU__FPGA_PL0_ENABLE {1} \
 CONFIG.PSU__USE__S_AXI_GP0 {0} CONFIG.PSU__USE__S_AXI_GP1 {0} CONFIG.PSU__USE__S_AXI_GP2 {1} CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} CONFIG.PSU__USE__S_AXI_GP3 $dual \
 CONFIG.PSU__USE__S_AXI_GP4 {0} CONFIG.PSU__USE__S_AXI_GP5 {0} CONFIG.PSU__USE__S_AXI_GP6 {0}] [get_bd_cells ps]
proc create_zu15eg_root {name catalog backend enable_gen3 link_width} {
 if {$catalog} {
  create_bd_cell -type ip -vlnv soft-pcie.org:user:soft_pcie_root:1.2 $name
  set modes [dict create legacy 0 gen2-x2 1 gen3 2 gen3-x2 3]
  set_property CONFIG.PCIE_MODE [dict get $modes $backend] [get_bd_cells $name]
 } else {
  create_bd_cell -type ip -vlnv soft-pcie.org:user:soft_pcie_root:1.1 $name
  set_property -dict [list CONFIG.ENABLE_GEN3 $enable_gen3 CONFIG.LINK_WIDTH $link_width] [get_bd_cells $name]
  foreach {mode parameter} {gen1-x2 X2_GEN1_BRINGUP gen2-x2 X2_GEN2_BRINGUP gen3-x2 X2_GEN3_BRINGUP} {
   if {[get_property CONFIG.$parameter [get_bd_cells $name]] != ($backend eq $mode)} {
    error "Packaged IP stage does not match $backend"
   }
  }
 }
}
create_zu15eg_root pcie $catalog $backend $enable_gen3 $link_width
# The DPLL yields the nominal 100 MHz with this board's PS reference,
# matching the integer-Hz metadata on the IP's 50/125 MHz clock interfaces.
if {[get_property CONFIG.FREQ_HZ [get_bd_pins ps/pl_clk0]] != 100000000} {
 error "PS PL0 must run at 100 MHz"
}
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
if {!$dual} {connect_bd_net [get_bd_pins pcie/irq_o] [get_bd_pins ps/pl_ps_irq0]}
foreach name {refclk_p_i refclk_n_i rx_p_i rx_n_i} {
 set width_args {}
 if {$x2_stage && [string match rx_* $name]} {set width_args {-from 1 -to 0}}
 create_bd_port -dir I {*}$width_args $name
 connect_bd_net [get_bd_ports $name] [get_bd_pins pcie/$name]
}
set outputs {tx_p_o tx_n_o}
if {$adapter eq "op063-a"} {lappend outputs perst_a_o disable_ssd2_power_o}
foreach name $outputs {
 set width_args {}
 if {$x2_stage && [string match tx_* $name]} {set width_args {-from 1 -to 0}}
 create_bd_port -dir O {*}$width_args $name
 connect_bd_net [get_bd_ports $name] [get_bd_pins pcie/$name]
}
assign_bd_address -offset 0xA0000000 -range 4K -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs pcie/S_AXI/reg0] -force
assign_bd_address -offset 0xA2000000 -range 32M -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs pcie/S_MEM/reg0] -force
proc assign_zu15eg_ddr {name hp addr_width full_ddr} {
 set space [get_bd_addr_spaces $name/M_DDR]
 set port ps/SAXIGP[expr {$hp + 2}]
 if {[get_property CONFIG.ADDR_WIDTH [get_bd_intf_pins $name/M_DDR]] != $addr_width} {
  error "Expected $addr_width DDR address bits on $name"
 }
 assign_bd_address -offset 0x00000000 -range 2G -target_address_space $space [get_bd_addr_segs $port/HP${hp}_DDR_LOW] -force
 set upper [get_bd_addr_segs $port/HP${hp}_DDR_HIGH]
 if {$full_ddr} {
  if {$addr_width != 36} {error "The full-DDR profile requires 36 address bits"}
  assign_bd_address -offset 0x800000000 -range 2G -target_address_space $space $upper -force
 } elseif {$addr_width == 36} {
  exclude_bd_addr_seg -target_address_space $space $upper
 }
}
set ddr_addr_width [get_property CONFIG.ADDR_WIDTH [get_bd_intf_pins pcie/M_DDR]]
if {$ddr_addr_width ni {32 36}} {error "Expected a 32- or 36-bit DDR address port"}
assign_zu15eg_ddr pcie 0 $ddr_addr_width $full_ddr
if {$dual} {source [file join $board_dir add_second_port.tcl]}
validate_bd_design
set ddr_width [expr {$x2_stage ? 128 : 64}]
set host_ddr_addr_width $ddr_addr_width
if {[get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells reset]]!=0} {error "PS reset must be active low"}
set root_names [expr {$dual ? {pcie pcie_b} : {pcie}}]
set read_outstanding [expr {$x2_stage ? 16 : $enable_gen3 ? 8 : 2}]
foreach name $root_names {
 foreach {property expected} [list ADDR_WIDTH $ddr_addr_width DATA_WIDTH $ddr_width FREQ_HZ 125000000 NUM_READ_OUTSTANDING $read_outstanding NUM_WRITE_OUTSTANDING 2] {
  if {[get_property CONFIG.$property [get_bd_intf_pins $name/M_DDR]] != $expected} {
   error "DDR master $name mismatch: $property expected $expected"
  }
 }
}
save_bd_design
set bd [get_files system.bd]
add_files -norecurse [make_wrapper -files $bd -top]
read_xdc [file join $board_dir constraints $adapter.xdc]
add_files -fileset constrs_1 $cdc_script
set cdc_file [get_files $cdc_script]
set_property FILE_TYPE TCL $cdc_file
set_property PROCESSING_ORDER LATE $cdc_file
# Packaged BD IPs are black boxes during top synthesis. Apply these constraints
# after open_run links their checkpoints, and normally during implementation.
set_property USED_IN_SYNTHESIS false $cdc_file
set_property top system_wrapper [current_fileset]
generate_target all $bd
set project_dir [get_property DIRECTORY [current_project]]
set generated_dir [file join $project_dir [get_property NAME [current_project]].gen]
set ps_init [file join $generated_dir sources_1 bd system ip system_ps_0 psu_init.tcl]
if {![file isfile $ps_init]} {error "Missing generated PS initialization Tcl: $ps_init"}
file copy $ps_init [file join $out psu_init.tcl]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
open_run synth_1
source $cdc_script
exec {*}$source_check check [file join $out sources.json] --board zu15eg
if {[llength [get_cells -hier -quiet -filter {REF_NAME =~ PCIE*}]]} {error "Soft test image contains PCIe hard macro"}
set gt_count [expr {$link_width * [llength $root_names]}]
if {[llength [get_cells -hier -quiet -filter {REF_NAME == GTHE4_CHANNEL}]] != $gt_count} {error "Expected $gt_count GTH channels"}
report_utilization -file [file join $out synth_utilization.rpt]
report_cdc -details -file [file join $out synth_cdc.rpt]
write_checkpoint [file join $out synthesized.dcp]
source $check_structure
set cdc_file [open [file join $out synth_cdc.rpt] r]
set cdc_check [read $cdc_file]
close $cdc_file
if {[regexp -line {^[[:space:]]*CDC-[0-9]+[[:space:]]+Critical[[:space:]]+[1-9]} $cdc_check]} {error "Unwaived critical synthesized CDC; image withheld"}
launch_runs impl_1 -to_step route_design -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation failed"}
open_run impl_1
exec {*}$source_check check [file join $out sources.json] --board zu15eg
report_timing_summary -report_unconstrained -file [file join $out timing.rpt]
report_utilization -hierarchical -file [file join $out utilization.rpt]
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
source $check_structure
if {$dual} {
 set pins {refclk_p_i L8 refclk_n_i L7 refclk_b_p_i G8 refclk_b_n_i G7}
 if {$x2_stage} {
  lappend pins {*}{rx_p_i[0] T2 rx_n_i[0] T1 tx_p_o[0] R4 tx_n_o[0] R3
                   rx_p_i[1] P2 rx_n_i[1] P1 tx_p_o[1] P6 tx_n_o[1] P5
                   rx_b_p_i[0] K2 rx_b_n_i[0] K1 tx_b_p_o[0] K6 tx_b_n_o[0] K5
                   rx_b_p_i[1] J4 rx_b_n_i[1] J3 tx_b_p_o[1] H6 tx_b_n_o[1] H5}
 } else {
  lappend pins {*}{rx_p_i T2 rx_n_i T1 tx_p_o R4 tx_n_o R3
                   rx_b_p_i K2 rx_b_n_i K1 tx_b_p_o K6 tx_b_n_o K5}
 }
 foreach {port pin} $pins {
  if {[get_property PACKAGE_PIN [get_ports $port]] ne $pin} {error "Expected pin $pin for $port"}
 }
}
set cdc_file [open [file join $out cdc.rpt] r]
set cdc_check [read $cdc_file]
close $cdc_file
if {[regexp -line {^[[:space:]]*CDC-[0-9]+[[:space:]]+Critical[[:space:]]+[1-9]} $cdc_check]} {error "Unwaived critical CDC; image withheld"}
if {$backend in {gen3 gen2-x2 gen3-x2}} {
 # Check Gen1 and Gen2 on the same routed design, then restore its fast mode.
 set native_clocks {}
 foreach name $root_names {
  current_instance system_i/$name
  set gt [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]
  set rate_high [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[1] || REF_PIN_NAME == RXRATE[1]}]
  set rate_low [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[0] || REF_PIN_NAME == RXRATE[0]}]
  set txclock [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]
  set clkname [get_property NAME [get_clocks -of_objects $txclock]]
  current_instance
  if {[llength $rate_high]!=2*$link_width || [llength $rate_low]!=2*$link_width || [llength $clkname]!=1} {
   error "Native rate pins or mode clock missing for $name"
  }
  lappend native_clocks $rate_high $rate_low $clkname $txclock
 }
 set modes {gen1 0 0 8 gen2 0 1 4}
 if {$backend in {gen3 gen3-x2}} {lappend modes gen3 1 0 4}
 foreach {mode high low period} $modes {
  foreach {rate_high rate_low clkname txclock} $native_clocks {
   set_case_analysis $high $rate_high
   set_case_analysis $low $rate_low
   create_clock -name $clkname -period $period $txclock
  }
  report_timing_summary -file [file join $out ${mode}_timing.rpt]
  foreach type {max min} {
   set path [get_timing_paths -delay_type $type -max_paths 1]
   if {![llength $path] || [get_property SLACK $path]<0} {error "$mode $type timing failed; image withheld"}
  }
 }
}
write_bitstream -force [file join $out system.bit]
write_hw_platform -fixed -force -file [file join $out system.xsa]
