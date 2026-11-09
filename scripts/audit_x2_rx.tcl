# SPDX-License-Identifier: Apache-2.0
# Additional ideal-boundary check; not a board/interface timing budget.
if {$argc != 2} {error "Usage: audit_x2_rx.tcl routed-checkpoint fresh-output"}
lassign $argv checkpoint output
if {[file exists $output]} {error "Fresh audit output required"}
file mkdir $output
open_checkpoint $checkpoint
set_param general.maxThreads 8
set_input_delay -clock link 0.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock link 0.000 [get_ports -filter {DIRECTION == OUT}]
report_timing_summary -delay_type min_max -report_unconstrained -file $output/timing.rpt
report_timing -max_paths 20 -file $output/worst_paths.rpt
set holds [get_timing_paths -delay_type min -max_paths 1000 -slack_lesser_than 0]
set f [open $output/hold_paths.tsv w]
puts $f "slack_ns	startpoint	endpoint"
foreach path $holds {
    puts $f "[get_property SLACK $path]	[get_property STARTPOINT_PIN $path]	[get_property ENDPOINT_PIN $path]"
}
close $f
report_utilization -file $output/utilization.rpt
report_route_status -file $output/route_status.rpt
report_drc -file $output/drc.rpt
close_design
