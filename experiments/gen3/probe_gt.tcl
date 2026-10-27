# Apache-2.0. Isolated Gen3 PHY feasibility probe; not a deployable PCIe core.
if {$argc != 2 || [lindex $argv 1] ni {raw pcie}} {
 error "Usage: probe_gt.tcl fresh-output-directory raw|pcie"
}
set pcie [expr {[lindex $argv 1] eq "pcie"}]
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output must be fresh: $output"}
file mkdir $output
create_project gen3_probe $output -part xczu7ev-ffvc1156-2-e
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name gen3_probe_gt
set ip [get_ips gen3_probe_gt]
set_property -dict [list CONFIG.CHANNEL_ENABLE X0Y15 CONFIG.TX_MASTER_CHANNEL X0Y15 CONFIG.RX_MASTER_CHANNEL X0Y15 \
 CONFIG.TX_LINE_RATE 8.0 CONFIG.RX_LINE_RATE 8.0 CONFIG.TX_PLL_TYPE QPLL1 CONFIG.RX_PLL_TYPE QPLL1 \
 CONFIG.TX_REFCLK_FREQUENCY 100 CONFIG.RX_REFCLK_FREQUENCY 100 \
 CONFIG.TX_DATA_ENCODING RAW CONFIG.RX_DATA_DECODING RAW \
 CONFIG.TX_USER_DATA_WIDTH 32 CONFIG.RX_USER_DATA_WIDTH 32 CONFIG.TX_INT_DATA_WIDTH 32 CONFIG.RX_INT_DATA_WIDTH 32 \
 CONFIG.PCIE_ENABLE $pcie CONFIG.PCIE_CORECLK_FREQ 250 CONFIG.PCIE_USERCLK_FREQ 250 \
 CONFIG.FREERUN_FREQUENCY 50] $ip
if {$pcie} {
 set_property CONFIG.TX_DIFF_SWING_EMPH_MODE PCIE_GEN3 $ip
 set_property CONFIG.ENABLE_OPTIONAL_PORTS {rxrate_in txrate_in rx8b10ben_in tx8b10ben_in rxheader_out rxheadervalid_out rxdatavalid_out txheader_in txsequence_in rxgearboxslip_in pcierategen3_out pcierateidle_out pcierstidle_in phystatus_out rxstatus_out txdetectrx_in txelecidle_in rxelecidle_out} $ip
}
set report [open "$output/properties.txt" w]
foreach p [lsort [list_property $ip]] {
 if {[string match CONFIG.* $p]} {puts $report "$p=[get_property $p $ip]"}
}
close $report
# Probe the internal-HDL encoding name without assuming public Wizard support.
if {$pcie} {
if {[catch {set_property -dict [list CONFIG.TX_DATA_ENCODING 128B130B CONFIG.RX_DATA_DECODING 128B130B] $ip} reason]} {
 set result [open "$output/encoding-probe.txt" w]
 puts $result "128B130B rejected: $reason"
 close $result
} else {
 set result [open "$output/encoding-probe.txt" w]
 puts $result "128B130B accepted; inspect generated primitive attributes before integration"
 close $result
}
}
generate_target all $ip
report_ip_status -file "$output/ip-status.txt"
create_ip_run $ip
launch_runs gen3_probe_gt_synth_1 -jobs 2
wait_on_run gen3_probe_gt_synth_1
set status [get_property STATUS [get_runs gen3_probe_gt_synth_1]]
if {![string match "*Complete*" $status]} {error "GT synthesis failed: $status"}
close_project
