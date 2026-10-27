# SPDX-License-Identifier: Apache-2.0
# Native PCIe PCS interface probe. Generation is not functional qualification.
if {$argc != 1} {error "Usage: probe_native_gt.tcl fresh-output-directory"}
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output must be fresh"}
file mkdir $output
create_project native_probe $output -part xczu7ev-ffvc1156-2-e
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name native_probe_gt
set ip [get_ips native_probe_gt]
set_property -dict [list CONFIG.CHANNEL_ENABLE X0Y15 CONFIG.TX_MASTER_CHANNEL X0Y15 CONFIG.RX_MASTER_CHANNEL X0Y15 \
 CONFIG.TX_LINE_RATE 8.0 CONFIG.RX_LINE_RATE 8.0 CONFIG.TX_PLL_TYPE QPLL1 CONFIG.RX_PLL_TYPE QPLL1 \
 CONFIG.TX_REFCLK_FREQUENCY 100 CONFIG.RX_REFCLK_FREQUENCY 100 \
 CONFIG.TX_DATA_ENCODING 8B10B CONFIG.RX_DATA_DECODING 8B10B \
 CONFIG.TX_USER_DATA_WIDTH 16 CONFIG.RX_USER_DATA_WIDTH 16 CONFIG.TX_INT_DATA_WIDTH 20 CONFIG.RX_INT_DATA_WIDTH 20 \
 CONFIG.PCIE_ENABLE true CONFIG.PCIE_CORECLK_FREQ 250 CONFIG.PCIE_USERCLK_FREQ 250 \
 CONFIG.LOCATE_USER_DATA_WIDTH_SIZING EXAMPLE_DESIGN CONFIG.LOCATE_COMMON CORE \
 CONFIG.LOCATE_RESET_CONTROLLER EXAMPLE_DESIGN \
 CONFIG.LOCATE_TX_USER_CLOCKING EXAMPLE_DESIGN CONFIG.LOCATE_RX_USER_CLOCKING EXAMPLE_DESIGN \
 CONFIG.FREERUN_FREQUENCY 50] $ip
set_property CONFIG.ENABLE_OPTIONAL_PORTS {bufgtce_out bufgtcemask_out bufgtdiv_out bufgtreset_out bufgtrstmask_out pcierateqpll1_in gtrefclk0_in cpllreset_in cpllpd_in drpclk_in rxrate_in txrate_in pcierategen3_out pcieusergen3rdy_out pcierateidle_out pcierstidle_in cplllock_out cpllfreqlock_in qpll1lock_out qpll1freqlock_in qpll1pd_in qpll1reset_in pcierateqpllpd_out pcierateqpllreset_out rxvalid_out phystatus_out rxstatus_out txdetectrx_in txelecidle_in rxelecidle_out txprecursor_in txmaincursor_in txpostcursor_in txdiffctrl_in rxpolarity_in rxlpmen_in loopback_in} $ip
generate_target all $ip
set report [open $output/properties.txt w]
foreach p [lsort [list_property $ip]] {
 if {[string match CONFIG.* $p]} {puts $report "$p=[get_property $p $ip]"}
}
close $report
create_ip_run $ip
launch_runs native_probe_gt_synth_1 -jobs 2
wait_on_run native_probe_gt_synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs native_probe_gt_synth_1]]]} {
 error "Native GT synthesis failed"
}
close_project
