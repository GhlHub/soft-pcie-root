# SPDX-License-Identifier: Apache-2.0
# Standalone synthesis only. Not a routed or physically verified PHY.
if {$argc != 1} {error "Usage: synth_sequencing.tcl fresh-output-directory"}
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output must be fresh"}
file mkdir $output
set source [file dirname [file normalize [info script]]]
foreach top {gen3_tx_schedule gen3_phy_control gen3_native_clock} {
    create_project -in_memory -part xczu7ev-ffvc1156-2-e
    switch $top {
        gen3_tx_schedule {set files {gen3_tx_schedule.sv gen3_tx_cadence.sv gen3_scrambler.sv}}
        gen3_phy_control {set files {gen3_phy_control.sv gen3_phy_rate.sv gen3_clock_watch.sv}}
        gen3_native_clock {set files {gen3_native_clock.sv}}
    }
    foreach f $files {read_verilog -sv $source/$f}
    synth_design -top $top -part xczu7ev-ffvc1156-2-e -mode out_of_context
    if {$top eq "gen3_tx_schedule"} {
        create_clock -name link_clk -period 4.000 [get_ports clk]
        report_timing_summary -file $output/${top}_timing.rpt
    }
    report_utilization -file $output/${top}_util.rpt
    write_checkpoint $output/${top}.dcp
    close_project
}
