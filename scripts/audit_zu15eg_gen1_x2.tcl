# SPDX-License-Identifier: Apache-2.0
# Reopen a ZU15EG x2 checkpoint and verify the passive FMC profile.
if {$argc ni {2 3}} {error "Supply routed checkpoint, fresh audit directory and optional gen2-x2 or gen3-x2 mode"}
lassign $argv checkpoint output audit_stage
if {$audit_stage ni {{} gen2-x2 gen3-x2}} {error "Unsupported x2 audit stage: $audit_stage"}
set root [file normalize [file join [file dirname [info script]] ..]]
set checkpoint [file normalize $checkpoint]
set output [file normalize $output]
if {[file exists $output]} {error "Use a fresh audit directory"}
exec python3 [file join $root scripts host_sources.py] check [file join [file dirname $checkpoint] sources.json] --board zu15eg
file mkdir $output
open_checkpoint $checkpoint
if {[get_property PART [current_project]] ne "xczu15eg-ffvb1156-2-i"} {error "Wrong target part"}
source [file join $root experiments gen3 check_host_structure.tcl]
if {$x2_native != 1 || $x2_gen2 != ($audit_stage ne "") || $x2_gen3 != ($audit_stage eq "gen3-x2")} {
 error "Wrong native x2 root stage"
}
set refbuf [get_cells -hier -filter {REF_NAME == IBUFDS_GTE4}]
if {[llength $refbuf] != 1 || [get_property LOC $refbuf] ne "GTHE4_COMMON_X1Y1" ||
    ![string match */IBUFDS0_GTHE4 [get_bels -of_objects $refbuf]]} {error "Wrong GBTCLK0 buffer"}
foreach {port pin} {
 refclk_p_i L8 refclk_n_i L7
 rx_p_i[0] T2 rx_n_i[0] T1 tx_p_o[0] R4 tx_n_o[0] R3
 rx_p_i[1] P2 rx_n_i[1] P1 tx_p_o[1] P6 tx_n_o[1] P5
} {
 set actual [get_property PACKAGE_PIN [get_ports $port]]
 if {$actual ne $pin} {error "Expected $port at $pin, found $actual"}
}
if {[llength [get_ports -quiet {perst_a_o disable_ssd2_power_o}]] ||
    ![string equal -nocase [get_property BITSTREAM.CONFIG.UNUSEDPIN [current_design]] "Pullnone"]} {
 error "Unexpected FMC sideband drive or pull setting"
}
foreach kind {clocks drc route_status cdc bus_skew} {
 report_$kind -file [file join $output $kind.rpt]
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {error "DRC failed"}
if {![regexp {# of nets with routing errors\.*\s*:\s*0} [report_route_status -return_string]]} {error "Routing errors"}
if {[regexp -line {^\s*CDC-\d+\s+Critical\s+[1-9]} [report_cdc -details -return_string]]} {error "Critical CDC"}
if {[regexp {Slack \(VIOLATED\)} [report_bus_skew -return_string]]} {error "Bus skew failed"}
set coverage [check_timing -verbose -return_string]
set coverage_file [open [file join $output check_timing.rpt] w]
puts -nonewline $coverage_file $coverage
close $coverage_file
foreach check {no_clock unconstrained_internal_endpoints no_input_delay} {
 if {![string match "*checking $check (0)*" $coverage]} {error "Timing coverage failed: $check"}
}
proc audit_x2_timing {mode file} {
 set timing [report_timing_summary -return_string]
 set stream [open $file w]
 puts $stream $timing
 close $stream
 if {![regexp -line {^\s*-?\d+\.\d+\s+-?\d+\.\d+\s+(\d+)\s+\d+\s+-?\d+\.\d+\s+-?\d+\.\d+\s+(\d+)\s+\d+\s+-?\d+\.\d+\s+-?\d+\.\d+\s+(\d+)\s+\d+\s*$} $timing -> setup hold pulse] ||
     $setup || $hold || $pulse} {error "Timing violations or missing timing summary for $mode"}
}
audit_x2_timing fastest [file join $output timing_summary.rpt]
if {$x2_gen2} {
 set lower [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[0] || REF_PIN_NAME == RXRATE[0]}]
 set upper [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[1] || REF_PIN_NAME == RXRATE[1]}]
 set txclock [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]
 set clock [get_clocks -of_objects $txclock]
 if {[llength $lower] != 4 || [llength $upper] != 4 || [llength $clock] != 1} {
  error "Missing native rate pins or clock"
 }
 set name [get_property NAME $clock]
 set_case_analysis 0 $upper
 if {$x2_gen3} {
  set_case_analysis 1 $lower
  create_clock -name $name -period 4 $txclock
  audit_x2_timing gen2 [file join $output gen2_timing.rpt]
 }
 set_case_analysis 0 $lower
 create_clock -name $name -period 8 $txclock
 audit_x2_timing gen1 [file join $output gen1_timing.rpt]
 if {$x2_gen3} {puts ZU15EG_GEN3_X2_REOPENED_AUDIT_PASS} else {puts ZU15EG_GEN2_X2_REOPENED_AUDIT_PASS}
} else {
 puts ZU15EG_GEN1_X2_REOPENED_AUDIT_PASS
}
