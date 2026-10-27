# SPDX-License-Identifier: Apache-2.0
# Integrated transport synthesis/CDC inspection. No full PHY or board image.
if {$argc != 1} {error "Usage: synth_integration.tcl fresh-output-directory"}
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output must be fresh"}
file mkdir $output
set source [file dirname [file normalize [info script]]]
create_project -in_memory -part xczu7ev-ffvc1156-2-e
foreach name {gen3_tx_path gen3_tx_completion gen3_phy_control gen3_phy_rate gen3_clock_watch gen3_tx_schedule gen3_tx_cadence gen3_scrambler} {
    read_verilog -sv $source/$name.sv
}
synth_design -top gen3_tx_path -part xczu7ev-ffvc1156-2-e -mode out_of_context
create_clock -name management -period 20.000 [get_ports mgmt_clk]
create_clock -name link -period 4.000 [get_ports user_clk]
# Scope asynchronous single-bit exceptions to the first synchronizer D pins.
# No whole-clock false paths; Gray bus retains a physical delay/skew bound.
set first_stage [get_pins -hier -regexp {.*(stop_sync|permit_sync|drain_sync|idle_sync|rate_sync|gen3_sync|pll_sync|tx_sync|rx_sync)_reg\[0\]/D$}]
if {[llength $first_stage] != 9} {error "Expected nine single-bit synchronizer entry pins"}
set_false_path -to $first_stage
set gray_src [get_cells -hier -regexp {.*watch_clock/gray_reg\[[0-9]+\]$}]
set gray_dst [get_cells -hier -regexp {.*watch_clock/gray_meta_reg\[[0-9]+\]$}]
if {[llength $gray_src] != 16 || [llength $gray_dst] != 16} {error "Gray counter CDC structure changed"}
set_max_delay -datapath_only 4.000 -from $gray_src -to $gray_dst
set_bus_skew 4.000 -from $gray_src -to $gray_dst
report_utilization -hierarchical -file $output/utilization.rpt
report_timing_summary -file $output/timing.rpt
report_bus_skew -file $output/bus_skew.rpt
report_cdc -details -file $output/cdc.rpt
report_exceptions -file $output/exceptions.rpt
write_checkpoint $output/transport.dcp
close_project
