# SPDX-License-Identifier: Apache-2.0
# Isolated synthesis estimate only: no placement, routing or I/O constraints.
if {$argc<1 || $argc>2} {error "Usage: synth_recovery_tx.tcl fresh-output-directory ?source-file?"}
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output must be fresh"}
set source [file join [file dirname [info script]] gen3_recovery_tx.sv]
if {$argc==2} {set source [file normalize [lindex $argv 1]]}
file mkdir $output
file copy $source $output/source.sv
read_verilog -sv $output/source.sv
synth_design -top gen3_recovery_tx -part xczu7ev-ffvc1156-2-e -mode out_of_context
create_clock -name tx_clk -period 4.0 [get_ports clk]
report_utilization -file $output/utilization.rpt
report_timing_summary -file $output/timing.rpt
report_timing -to [get_cells -hier -filter {NAME =~ correction_reg*}] \
    -max_paths 5 -file $output/correction.rpt
