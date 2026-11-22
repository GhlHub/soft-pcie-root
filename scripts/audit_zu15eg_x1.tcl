# SPDX-License-Identifier: Apache-2.0
# Reopen a routed ZU15EG OP063 SSD A checkpoint without the build project.
if {[llength $argv] != 2} {error "Supply routed checkpoint and fresh audit directory"}
set root [file normalize [file join [file dirname [info script]] ..]]
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error "Use a fresh audit directory"}
exec python3 [file join $root scripts host_sources.py] check [file join [file dirname $checkpoint] sources.json] --board zu15eg
file mkdir $out
open_checkpoint $checkpoint
if {[get_property PART [current_project]] ne "xczu15eg-ffvb1156-2-i"} {error "Wrong target part"}
set gt [get_cells -hier -quiet -filter {REF_NAME == GTHE4_CHANNEL}]
set refbuf [get_cells -hier -quiet -filter {REF_NAME == IBUFDS_GTE4}]
if {[llength $gt] != 1 || [get_property LOC $gt] ne "GTHE4_CHANNEL_X1Y4"} {error "Wrong DP0 transceiver"}
if {[llength $refbuf] != 1 || [get_property LOC $refbuf] ne "GTHE4_COMMON_X1Y1" ||
    ![string match */IBUFDS0_GTHE4 [get_bels -of_objects $refbuf]]} {error "Wrong REFCLK0 buffer"}
if {[llength [get_cells -hier -quiet -filter {REF_NAME =~ PCIE*}]]} {error "Unexpected PCIe hard block"}
foreach {port pin} {refclk_p_i L8 refclk_n_i L7 rx_p_i T2 rx_n_i T1 tx_p_o R4 tx_n_o R3 perst_a_o R10 disable_ssd2_power_o M11} {
 set pin_name [get_property PACKAGE_PIN [get_ports $port]]
 if {$pin_name ne $pin} {error "Wrong package pin for $port: $pin_name, expected $pin"}
}
foreach port {perst_a_o disable_ssd2_power_o} {
 if {[get_property IOSTANDARD [get_ports $port]] ne "LVCMOS18"} {error "Wrong FMC sideband voltage standard"}
}
set gen3 [llength [get_cells -hier -quiet -filter {ORIG_REF_NAME == gen3_native_root || REF_NAME == gen3_native_root}]]
if {$gen3} {
 source [file join $root experiments gen3 check_host_structure.tcl]
} else {
 source [file join $root examples zcu104 check_structure.tcl]
}
report_clocks -file [file join $out clocks.rpt]
report_utilization -file [file join $out utilization.rpt]
report_drc -file [file join $out drc.rpt]
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {error "DRC failed"}

proc save_report {path contents} {
 set file [open $path w]
 puts -nonewline $file $contents
 close $file
 return $contents
}
set route [save_report [file join $out route.rpt] [report_route_status -return_string]]
if {![regexp {# of nets with routing errors\.*\s*:\s*0} $route]} {error "Routing errors or missing route summary"}
set cdc [save_report [file join $out cdc.rpt] [report_cdc -details -return_string]]
if {[regexp -line {^\s*CDC-\d+\s+Critical\s+[1-9]} $cdc]} {error "Unwaived critical CDC"}
set skew [save_report [file join $out bus_skew.rpt] [report_bus_skew -return_string]]
if {[regexp {Slack \(VIOLATED\)} $skew]} {error "Bus skew failed"}
set coverage [save_report [file join $out check_timing.rpt] [check_timing -verbose -return_string]]
foreach check {no_clock unconstrained_internal_endpoints no_input_delay} {
 if {![string match "*checking $check (0)*" $coverage]} {error "Timing coverage failed: $check"}
}

proc audit_timing {report} {
 set timing [save_report $report [report_timing_summary -return_string]]
 if {![regexp -line {^\s*-?\d+\.\d+\s+-?\d+\.\d+\s+(\d+)\s+\d+\s+-?\d+\.\d+\s+-?\d+\.\d+\s+(\d+)\s+\d+\s+-?\d+\.\d+\s+-?\d+\.\d+\s+(\d+)\s+\d+\s*$} $timing -> setup hold pulse] ||
     $setup || $hold || $pulse} {error "Timing violations or missing timing summary in $report"}
}
audit_timing [file join $out timing.rpt]
if {$gen3} {
 set upper [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[1] || REF_PIN_NAME == RXRATE[1]}]
 set lower [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[0] || REF_PIN_NAME == RXRATE[0]}]
 set txclock [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]
 set clock [get_clocks -of_objects $txclock]
 if {[llength $upper] != 2 || [llength $lower] != 2 || [llength $clock] != 1} {error "Missing native rate pins or clock"}
 set clock_name [get_property NAME $clock]
 foreach {mode low period} {gen1 0 8 gen2 1 4} {
  set_case_analysis 0 $upper
  set_case_analysis $low $lower
  create_clock -name $clock_name -period $period $txclock
  audit_timing [file join $out ${mode}_timing.rpt]
 }
}
puts "ZU15EG_X1_REOPENED_AUDIT_PASS"
