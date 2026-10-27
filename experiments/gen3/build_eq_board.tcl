# SPDX-License-Identifier: Apache-2.0
# Locally generate AMD PHY RTL, migrate GTH wrapper to ZU7EV, build training-only image.
if {$argc != 1} {error "Usage: build_eq_board.tcl fresh-output-directory"}
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output must be fresh"}
file mkdir $output
set source [file dirname [file normalize [info script]]]
set root [file normalize $source/../..]
exec python3 $source/eq_board_sources.py capture $output/sources.json
create_project phy_reference $output/phy_reference -part xczu9eg-ffvb1156-2-e
create_ip -name pcie_phy -vendor xilinx.com -library ip -module_name gen3_reference_phy
set_property -dict [list CONFIG.gt_type GTH CONFIG.phy_lane X1 CONFIG.phy_max_speed 8.0_GT/s \
    CONFIG.phy_refclk_freq 100_MHz CONFIG.phy_userclk_freq 250_MHz CONFIG.phy_coreclk_freq 250_MHz \
    CONFIG.tx_preset 4 CONFIG.aspm No_ASPM CONFIG.phy_async_en false \
    CONFIG.lane0_gt_bank GTH_Quad_130 CONFIG.lane0_gt_location GTHE4_CHANNEL_X0Y15 \
    CONFIG.refclk1_location Bank_130_MGTREFCLK0] [get_ips gen3_reference_phy]
generate_target all [get_ips gen3_reference_phy]
set base $output/phy_reference/phy_reference.gen/sources_1/ip/gen3_reference_phy
close_project
exec python3 $source/instrument_eq_phy.py $base $output/observed_phy --startup-reference
create_project eq_board $output/board -part xczu7ev-ffvc1156-2-e
foreach dir {source synth ip_0/synth ip_0/hdl} {
    foreach f [glob $base/$dir/*.v] {
        set observed $output/observed_phy/[file tail $f]
        if {[file exists $observed]} {read_verilog $observed} else {read_verilog $f}
    }
}
foreach name {gen3_eq_board gen3_eq_bringup gen3_legacy_training gen3_startup_ltssm gen3_training_tx gen3_training_rx gen3_recovery_tx gen3_dllp_source gen3_link_layer gen3_replay_tx gen3_tx_window gen3_tlp_source gen3_stp gen3_native_rx gen3_data_rx gen3_stream_rx gen3_stream_buffered_rx gen3_packet_gate gen3_eq_phase1 gen3_clock_watch} {
    read_verilog -sv $source/$name.sv
}
read_verilog -sv $root/ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_scrambler.sv
read_verilog -sv $root/ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_flow_control.sv
foreach name {pcie_soft_requester pcie_soft_replay pcie_soft_ack_capture} {
 read_verilog -sv $root/ip/soft_pcie_root/rtl/pcie_soft/$name.sv
}
create_ip -name vio -vendor xilinx.com -library ip -module_name gen3_eq_vio
set_property -dict [list CONFIG.C_NUM_PROBE_IN 5 CONFIG.C_NUM_PROBE_OUT 2 \
    CONFIG.C_PROBE_IN0_WIDTH 128 CONFIG.C_PROBE_IN1_WIDTH 128 CONFIG.C_PROBE_IN2_WIDTH 32 CONFIG.C_PROBE_IN3_WIDTH 64 CONFIG.C_PROBE_IN4_WIDTH 64 \
    CONFIG.C_PROBE_OUT0_WIDTH 1 CONFIG.C_PROBE_OUT1_WIDTH 4 \
    CONFIG.C_PROBE_OUT0_INIT_VAL 0 CONFIG.C_PROBE_OUT1_INIT_VAL 4] [get_ips gen3_eq_vio]
set_property generate_synth_checkpoint false [get_files gen3_eq_vio.xci]
generate_target all [get_ips gen3_eq_vio]
# Passive receive diagnostics, clocked directly by PCLK.
set_property verilog_define GEN3_RX_DIAGNOSTICS [current_fileset]
create_ip -name ila -vendor xilinx.com -library ip -module_name gen3_rx_ila
set diag_config [list CONFIG.C_NUM_OF_PROBES 14 CONFIG.C_DATA_DEPTH 8192 CONFIG.C_EN_STRG_QUAL 1 CONFIG.C_INPUT_PIPE_STAGES 1]
for {set i 0} {$i<14} {incr i} {lappend diag_config CONFIG.C_PROBE${i}_WIDTH 32}
# Only decoded RX data and the RX/TX event buses need trigger comparators.
# Counters, raw words and the timer are capture-only probes.
foreach i {0 3 4 5 6 7 8 9 10 12 13} {lappend diag_config CONFIG.C_PROBE${i}_TYPE 1}
set_property -dict $diag_config [get_ips gen3_rx_ila]
set_property generate_synth_checkpoint false [get_files gen3_rx_ila.xci]
generate_target all [get_ips gen3_rx_ila]
update_compile_order -fileset sources_1
set_property top gen3_eq_board [current_fileset]
# Use generated PHY clock/mode constraints, but not its broad clock groups.
# Crossings are reviewed and constrained at synchronizer/mailbox endpoints below.
read_xdc $base/source/ip_pcie_phy.xdc
read_xdc $base/ip_0/synth/gen3_reference_phy_gt.xdc
read_xdc $root/examples/zcu104/constraints/zcu104_fmc.xdc
synth_design -top gen3_eq_board -part xczu7ev-ffvc1156-2-e
if {[llength [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]]!=1} {error "Expected one GTH"}
if {[llength [get_cells -hier -filter {REF_NAME =~ PCIE*}]]} {error "Unexpected PCIe controller hard block"}
source $source/eq_board_constraints.tcl
report_utilization -hierarchical -file $output/synth_utilization.rpt
report_cdc -details -file $output/synth_cdc.rpt
set cf [open $output/synth_cdc.rpt r]
set synth_cdc_text [read $cf]
close $cf
if {[regexp -line {^CDC-[0-9]+[[:space:]]+Critical[[:space:]]+[1-9]} $synth_cdc_text]} {
    error "Unreviewed critical synthesis CDC; stop before implementation"
}
write_checkpoint $output/synthesized.dcp
exec python3 $source/eq_board_sources.py check $output/sources.json
opt_design
place_design
phys_opt_design
route_design
write_checkpoint $output/pre_audit_routed.dcp
source $source/audit_ila_config_cdc.tcl
gen3_review_ila_config_cdc $output
report_timing_summary -file $output/timing.rpt
report_cdc -details -file $output/cdc.rpt
report_drc -file $output/drc.rpt
report_route_status -file $output/route.rpt
report_bus_skew -file $output/bus_skew.rpt
report_utilization -hierarchical -file $output/utilization.rpt
check_timing -verbose -file $output/check_timing.rpt
set cdc_text [read [set cf [open $output/cdc.rpt r]]]
close $cf
if {[regexp -line {^CDC-[0-9]+[[:space:]]+Critical[[:space:]]+[1-9]} $cdc_text]} {
    error "Unreviewed critical CDC; no bitstream"
}
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error || SEVERITY == {Critical Warning}}]]} {
    error "DRC failed; no bitstream"
}
write_checkpoint $output/routed.dcp
exec python3 $source/eq_board_sources.py check $output/sources.json
foreach type {max min} {
    set paths [get_timing_paths -delay_type $type -max_paths 1]
    if {![llength $paths] || [get_property SLACK $paths]<0} {error "Routed $type timing failed; no bitstream"}
}
# Also check the 125 MHz Gen1 mode on the same routed implementation.
set gt [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]
set rate_bits [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXRATE[1] || REF_PIN_NAME == RXRATE[1]}]
if {[llength $rate_bits]!=2} {error "Missing native rate mode pins"}
set txclock [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]
set_case_analysis 0 $rate_bits
create_clock -name txoutclk -period 8 $txclock
report_timing_summary -file $output/gen1_timing.rpt
foreach type {max min} {
    set paths [get_timing_paths -delay_type $type -max_paths 1]
    if {![llength $paths] || [get_property SLACK $paths]<0} {error "Gen1 routed $type timing failed"}
}
set_case_analysis 1 $rate_bits
create_clock -name txoutclk -period 4 $txclock
# CDC warnings and timing coverage still require explicit review before deployment.
write_bitstream $output/equalization.bit
write_debug_probes $output/equalization.ltx
close_project
