# SPDX-License-Identifier: Apache-2.0
# Routed out-of-context measurements, NOT an integrated board implementation.
if {$argc != 4} {error "Usage: route_x2_blocks.tcl snapshot-root output part target"}
lassign $argv root output part target
set root [file normalize $root]
set output [file normalize $output]
if {[file exists $output]} {error "Fresh target output required"}
file mkdir $output
set_param general.maxThreads 8
create_project -in_memory -part $part
foreach f [glob $root/experiments/gen3/*.sv $root/ip/soft_pcie_root/rtl/host/*.sv $root/ip/soft_pcie_root/rtl/pcie_soft/*.sv] {
    read_verilog -sv $f
}
set generic {}
if {$target in {gen3_multilane_startup gen3_multilane_eq}} {set generic {LINK_WIDTH=2}}
synth_design -top $target -part $part -mode out_of_context -flatten_hierarchy rebuilt -generic $generic
if {$target eq "pcie_x2_host_path"} {
    create_clock -name host -period 8.000 [get_ports clk]
    create_clock -name link -period 4.000 [get_ports link_clk]
    # Bound Gray crossings; do not cut whole clock domains.
    # Bundled RAM paths retain nominal related-clock timing. This resource
    # measurement does not qualify asynchronous bundled-data CDC timing.
    foreach instance {rx_cdc tx_cdc} {
        foreach {srcname dstname} {s_gray_q m_write_meta_q m_gray_q s_read_meta_q} {
            set src [get_cells -hier -regexp [format {.*%s/%s_reg\[[0-9]+\]$} $instance $srcname]]
            set dst [get_cells -hier -regexp [format {.*%s/%s_reg\[[0-9]+\]$} $instance $dstname]]
            if {[llength $src] != 3 || [llength $dst] != 3} {error "Unexpected Gray geometry $instance $srcname $dstname"}
            set_max_delay -datapath_only 4.000 -from $src -to $dst
            set_bus_skew 4.000 -from $src -to $dst
        }

    }
    set first [get_pins -hier -regexp {.*tx_fault_sync_reg\[0\]/D$}]
    if {[llength $first] != 1} {error "Missing diagnostic synchronizer"}
    set_false_path -to $first
    set clears [get_pins -hier -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
    if {[llength $clears]} {set_false_path -from [get_ports rst_n] -to $clears}
} else {
    create_clock -name link -period 4.000 [get_ports clk]
}
# External interfaces intentionally unconstrained: these are internal block
# measurements, not pin-to-pin board timing or a replacement for a CDC audit.
report_utilization -hierarchical -file $output/post_synth_utilization.rpt
write_checkpoint $output/post_synth.dcp
opt_design
place_design
phys_opt_design
route_design
write_checkpoint $output/routed.dcp
report_utilization -file $output/utilization.rpt
report_utilization -hierarchical -file $output/hierarchy.rpt
report_timing_summary -delay_type min_max -report_unconstrained -file $output/timing.rpt
report_timing -max_paths 20 -file $output/worst_paths.rpt
report_route_status -file $output/route_status.rpt
report_drc -file $output/drc.rpt
report_exceptions -file $output/exceptions.rpt
if {$target eq "pcie_x2_host_path"} {
    report_cdc -details -file $output/cdc.rpt
    report_bus_skew -file $output/bus_skew.rpt
}
set f [open $output/complete.txt w]
puts $f "Routed OOC $target $part; external timing unconstrained; no integrated PHY/board"
close $f
close_project
