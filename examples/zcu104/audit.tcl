if {[llength $argv]!=2} {error "Supply routed DCP and fresh audit output"}
set output [file normalize [lindex $argv 1]]
file mkdir $output
open_checkpoint [lindex $argv 0]
set gt [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]
if {[llength $gt]!=1 || [get_property LOC $gt] ne "GTHE4_CHANNEL_X0Y15"} {error "Wrong physical FMC lane"}
if {[llength [get_cells -hier -quiet -filter {REF_NAME =~ PCIE*}]]} {error "Hard PCIe block in soft image"}
if {[get_property TXBUF_EN $gt] ne "TRUE"} {error "PCIe reset release requires the reviewed buffered TX configuration"}
set calibrated_lock [get_cells -hier -regexp {.*gthe4_cpll_cal_tx_i/USER_CPLLLOCK_OUT_reg}]
if {[llength $calibrated_lock]!=1} {error "Expected one AMD calibrated CPLL lock register"}
set lock_out [get_pins -of_objects $calibrated_lock -filter {REF_PIN_NAME == Q}]
set lock_feedback [get_pins -of_objects $gt -filter {REF_PIN_NAME == CPLLFREQLOCK}]
set lock_segments [get_nets -segments -of_objects $lock_out]
if {[llength $lock_feedback]!=1 || [lsearch -exact $lock_segments [get_nets -of_objects $lock_feedback]]<0} {error "Missing PCIe calibrated CPLL lock feedback"}
set pcie_reset [get_nets -of_objects [get_pins -of_objects $gt -filter {REF_PIN_NAME == PCIERSTIDLE}]]
if {![llength $pcie_reset] || [get_property TYPE $pcie_reset] ne "SIGNAL"} {error "PCIe reset release tied constant"}
set reset_sources [all_fanin -flat -startpoints_only -to [get_pins -of_objects $gt -filter {REF_PIN_NAME == PCIERSTIDLE}]]
set ready_sources [lsearch -all -inline -regexp $reset_sources {.*phy/ready_sync_reg\[[0-4]\]/C$}]
if {[llength $reset_sources]!=6 || [llength $ready_sources]!=5} {error "Unexpected PCIe reset release sources"}
puts "PCIE_PHY_RESET_WIRING_PASS buffered_TX calibrated_CPLL_lock_feedback ready_and_global_reset"
foreach {p expected} {PCS_PCIE_EN TRUE CLK_CORRECT_USE TRUE CLK_COR_KEEP_IDLE TRUE CLK_COR_SEQ_LEN 1 CLK_COR_SEQ_1_1 10'b0100011100 CLK_COR_SEQ_1_ENABLE 4'b1111} {
 if {[get_property $p $gt] ne $expected} {error "Wrong GTH attribute $p"}
 puts "GTH_ATTRIBUTE_PASS $p=$expected"
}
if {abs([get_property PERIOD [get_clocks pcie_core]]-4.0)>0.001} {error "Wrong core clock"}
if {[get_property PACKAGE_PIN [get_ports perst_a_o]] ne "F17" || [get_property PACKAGE_PIN [get_ports disable_ssd2_power_o]] ne "J16"} {error "Wrong OP063 controls"}
set perst_ff [get_cells -hier -quiet -filter {NAME =~ *root_port/perst_asserted_q_reg}]
if {[llength $perst_ff]!=1 || [get_property REF_NAME $perst_ff] ni {FDRE FDSE}} {error "PERST must be registered in management domain"}
source [file join [file dirname [info script]] check_structure.tcl]
report_clocks -file [file join $output clocks.rpt]
report_timing_summary -file [file join $output timing.rpt]
report_cdc -details -file [file join $output cdc.rpt]
report_bus_skew -file [file join $output bus_skew.rpt]
report_utilization -file [file join $output utilization.rpt]
report_drc -file [file join $output drc.rpt]
report_route_status -file [file join $output route.rpt]
check_timing -verbose -file [file join $output check_timing.rpt]
puts "ZCU104_REOPENED_STRUCTURE_PASS"
