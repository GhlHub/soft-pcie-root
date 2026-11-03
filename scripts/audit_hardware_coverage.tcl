# SPDX-License-Identifier: Apache-2.0
# Read-only acceptance audit for an isolated diagnostic checkpoint.
if {$argc!=3} {error "Supply routed checkpoint, fresh audit directory and package directory; run from source snapshot"}
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error "Audit output must be fresh"}
file mkdir $out
open_checkpoint [lindex $argv 0]
set gt [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]
if {[llength $gt]!=1 || [get_property LOC $gt] ne "GTHE4_CHANNEL_X0Y15"} {error "Wrong lane"}
if {[llength [get_cells -hier -quiet -filter {REF_NAME =~ PCIE*}]]} {error "Unexpected hard PCIe block"}
source experiments/gen3/check_host_structure.tcl
report_timing_summary -file $out/timing.rpt
report_timing -group txoutclk -max_paths 100 -nworst 1 -file $out/pcie_top100.rpt
report_clocks -file $out/clocks.rpt
report_cdc -details -file $out/cdc.rpt
report_bus_skew -file $out/bus_skew.rpt
report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -file $out/utilization_hierarchical.rpt
report_drc -file $out/drc.rpt
report_route_status -file $out/route.rpt
check_timing -verbose -file $out/check_timing.rpt
report_control_sets -verbose -file $out/control_sets.rpt
foreach type {max min} {
 set path [get_timing_paths -delay_type $type -max_paths 1]
 if {![llength $path] || [get_property SLACK $path]<0} {error "Timing failed"}
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {error "DRC failed"}
if {[regexp {Slack \(VIOLATED\)} [report_bus_skew -return_string]]} {error "Skew failed"}
set rate_bits [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[1] || REF_PIN_NAME == RXRATE[1]}]
set txclock [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]
set clkname [get_property NAME [get_clocks -of_objects $txclock]]
if {[llength $rate_bits]!=2 || [llength $clkname]!=1} {error "Native mode clocks missing"}
set rate_low [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[0] || REF_PIN_NAME == RXRATE[0]}]
if {[llength $rate_low]!=2} {error "Native low rate bits missing"}
foreach {mode low period} {gen1 0 8 gen2 1 4} {
 set_case_analysis 0 $rate_bits
 set_case_analysis $low $rate_low
 create_clock -name $clkname -period $period $txclock
 report_timing_summary -file $out/${mode}_timing.rpt
 foreach type {max min} {
  set path [get_timing_paths -delay_type $type -max_paths 1]
  if {![llength $path] || [get_property SLACK $path]<0} {error "$mode timing failed"}
 }
}
set f [open $out/cdc.rpt r]; set cdc [read $f]; close $f
if {[regexp -line {^[[:space:]]*CDC-[0-9]+[[:space:]]+Critical[[:space:]]+[1-9]} $cdc]} {error "Unwaived critical CDC"}
if {![regexp -line {^CDC-11[[:space:]]+12[[:space:]]*$} $cdc]} {error "Reset waiver scope changed"}
set f [open $out/check_timing.rpt r]; set coverage [read $f]; close $f
foreach check {no_clock constant_clock pulse_width_clock unconstrained_internal_endpoints no_input_delay multiple_clock generated_clocks loops partial_input_delay partial_output_delay latch_loops} {
 if {![string match "*checking $check (0)*" $coverage]} {error "Timing coverage failed: $check"}
}
if {![string match "*checking no_output_delay (1)*" $coverage] || ![string match "*perst_a_o*" $coverage]} {error "Output delay exception scope changed"}
set f [open $out/route.rpt r]; set route [read $f]; close $f
if {![regexp {# of nets with routing errors[. ]*:[ ]+0[ ]*:} $route]} {error "Routing errors"}
set native [get_cells -hier -quiet -filter {REF_NAME == gen3_native_root || ORIG_REF_NAME == gen3_native_root}]
set legacy [get_cells -hier -quiet -filter {REF_NAME == pcie_soft_root_port || ORIG_REF_NAME == pcie_soft_root_port}]
if {[llength $native]!=1 || [llength $legacy]!=0} {error "Wrong unified catalog backend"}
exec python3 scripts/host_sources.py check [file join [lindex $argv 2] sources.json]
exec python3 scripts/host_sources.py check [file join [file dirname [lindex $argv 0]] sources.json]
puts "HARDWARE_COVERAGE_REOPENED_AUDIT_PASS"
