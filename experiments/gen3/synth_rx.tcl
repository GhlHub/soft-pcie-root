# SPDX-License-Identifier: Apache-2.0
# Standalone logic estimate; no pin/GT/CDC integration or routed timing claim.
if {$argc != 1} {error "Usage: synth_rx.tcl fresh-output-directory"}
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output must be fresh"}
file mkdir $output
read_verilog -sv [file join [file dirname [info script]] gen3_eieos_detect.sv]
read_verilog -sv [file join [file dirname [info script]] gen3_rx_blocks.sv]
synth_design -top gen3_rx_blocks -part xczu7ev-ffvc1156-2-e -mode out_of_context
create_clock -name rx_clk -period 4.0 [get_ports clk]
report_utilization -file $output/utilization.rpt
report_timing_summary -file $output/timing.rpt
write_checkpoint $output/rx.dcp
