# SPDX-License-Identifier: Apache-2.0
# Run with Vivado: fresh output directory, unified core repository.
if {$argc!=2} {error "Supply fresh output and unified core directory"}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Use fresh output"}
set repo [file normalize [lindex $argv 1]]
set root [file normalize [file join [file dirname [info script]] ..]]
create_project catalog_selection $out -part xczu7ev-ffvc1156-2-e
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
set_property ip_repo_paths $repo [current_project]
update_ip_catalog
set definitions [get_ipdefs -all -filter {VLNV =~ soft-pcie.org:*}]
if {[llength $definitions]!=1 || [get_property VLNV $definitions] ne "soft-pcie.org:user:soft_pcie_root:1.1"} {error "Expected one unified catalog definition"}
create_bd_design selection_metadata
foreach mode {0 1} {
 set cell [create_bd_cell -type ip -vlnv soft-pcie.org:user:soft_pcie_root:1.1 bd_$mode]
 if {$mode==0 && [get_property CONFIG.ENABLE_GEN3 $cell] ni {false 0}} {error "Gen3 must default off"}
 # Toggle each existing customization both ways to catch stale GUI dependencies.
 foreach enabled {true false true false} {
  set_property CONFIG.ENABLE_GEN3 $enabled $cell
  set expected [expr {$enabled ? 8 : 2}]
  set bus [get_bd_intf_pins bd_$mode/M_DDR]
  if {[get_property CONFIG.NUM_READ_OUTSTANDING $bus]!=$expected} {error "Outstanding-read metadata did not follow checkbox: $enabled"}
  if {[get_property CONFIG.DATA_WIDTH $bus]!=64 || [get_property CONFIG.NUM_WRITE_OUTSTANDING $bus]!=2} {error "DDR interface changed"}
 }
 set_property CONFIG.ENABLE_GEN3 $mode $cell
 create_ip -vlnv soft-pcie.org:user:soft_pcie_root:1.1 -module_name selected_$mode
 set_property CONFIG.ENABLE_GEN3 $mode [get_ips selected_$mode]
 generate_target all [get_ips selected_$mode]
 set wrapper_file [open [glob $out/*.gen/sources_1/ip/selected_$mode/synth/selected_$mode.v] r]
 set wrapper [read $wrapper_file];close $wrapper_file
 if {![string match "*.ENABLE_GEN3($mode)*" $wrapper]} {error "Generated HDL parameter did not follow checkbox"}
 # Vivado's standalone wrapper retains default bus annotations; supported AXI
 # automation uses the packaged BD cell whose live metadata is checked above.
}
save_bd_design
foreach mode {0 1} {
 create_ip_run [get_ips selected_$mode]
 launch_runs selected_${mode}_synth_1 -jobs 4
 wait_on_run selected_${mode}_synth_1
 if {[get_property PROGRESS [get_runs selected_${mode}_synth_1]] ne "100%"} {error "IP synthesis failed"}
 set log_file [open [file join [get_property DIRECTORY [get_runs selected_${mode}_synth_1]] runme.log] r]
 set synthesis_log [read $log_file];close $log_file
 if {[regexp {CRITICAL WARNING:|ERROR:} $synthesis_log]} {error "Synthesis has critical warnings/errors"}
 open_run selected_${mode}_synth_1
 set native_clock [get_clocks -quiet *txoutclk]
 if {[llength $native_clock]!=$mode} {error "Native constraints applied to wrong selection"}
 set gt [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]
 if {[llength $gt]!=1} {error "Expected exactly one selected GTH"}
 if {[llength [get_cells -hier -quiet -filter {REF_NAME =~ PCIE*}]]} {error "Hard PCIe unexpectedly instantiated"}
 set correct [get_cells -hier -quiet -filter "NAME =~ *gen[expr {$mode ? 3 : 2}]_mode.root_port*"]
 set wrong [get_cells -hier -quiet -filter "NAME =~ *gen[expr {$mode ? 2 : 3}]_mode.root_port*"]
 if {![llength $correct] || [llength $wrong]} {error "Wrong backend elaborated"}
 foreach fifo {rx_crossing tx_crossing} {
  set ram [get_cells -hier -filter "NAME =~ */$fifo/data_q_reg && REF_NAME =~ RAMB*"]
  if {[llength $ram]!=1 || [get_property READ_WIDTH_A $ram]!=[expr {$mode ? 72 : 36}]} {error "Wrong packet RAM width: $fifo"}
 }
 set owners [get_cells -hier -regexp {.*ddr/read_pending_q_reg\[[0-9]+\]}]
 if {[llength $owners]!=[expr {$mode ? 4 : 2}]} {error "Wrong AXI read ownership capacity"}
 create_clock -name host_test -period 8 [get_ports host_clk_i]
 create_clock -name management_test -period 20 [get_ports aclk]
 create_clock -name reference_test -period 10 [get_ports refclk_p_i]
 source $root/examples/zcu104/constraints/zcu104_cdc.tcl
 set link_clock [get_clocks -of_objects [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]]
 if {[llength $link_clock]!=1 || abs([get_property PERIOD $link_clock]-4.0)>0.001} {error "Selected link clock is not 250 MHz"}
 report_cdc -details -file $out/selected_$mode-cdc.rpt
 set cdc_file [open $out/selected_$mode-cdc.rpt r]
 set cdc_report [read $cdc_file];close $cdc_file
 if {[regexp -line {^[[:space:]]*CDC-[0-9]+[[:space:]]+Critical[[:space:]]+[1-9]} $cdc_report]} {error "Unwaived critical CDC"}
 report_utilization -file $out/selected_$mode-utilization.rpt
 write_checkpoint $out/selected_$mode.dcp
 puts "CATALOG_SELECTION_SYNTH_PASS ENABLE_GEN3=$mode"
 close_design
}
puts "CATALOG_GUI_BOTH_CONFIGURATIONS_PASS"
