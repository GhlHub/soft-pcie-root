# SPDX-License-Identifier: Apache-2.0
# Management mailbox/single-bit CDC. No whole-clock false paths.
set first [get_pins -hier -regexp {.*(release_sync|ready_sync|idle_sync|request_sync|ack_sync)_reg\[0\]/D$}]
if {[llength $first]!=5} {error "Expected five board synchronizer entry pins"}
set_false_path -to $first
set diag_first [get_pins -hier -regexp {^phy_diag_meta_reg\[[0-9]+\]/D$}]
if {![llength $diag_first]} {error "Missing diagnostic synchronizers"}
set_false_path -to $diag_first
set gray_src [get_cells -hier -regexp {.*clock_monitor/gray_reg\[[0-9]+\]$}]
set gray_dst [get_cells -hier -regexp {.*clock_monitor/gray_meta_reg\[[0-9]+\]$}]
if {[llength $gray_src]!=16 || [llength $gray_dst]!=16} {error "Clock monitor Gray CDC changed"}
set_max_delay -datapath_only 4 -from $gray_src -to $gray_dst
set_bus_skew 4 -from $gray_src -to $gray_dst
set snapshot_src [get_cells -hier -regexp {^snapshot_reg\[[0-9]+\]$}]
set snapshot_dst [get_cells -hier -regexp {^display_snapshot_reg\[[0-9]+\]$}]
# Constant bits can be optimized out; the request/ack protocol holds the bundle.
if {![llength $snapshot_src] || ![llength $snapshot_dst]} {error "Missing snapshot mailbox"}
set_max_delay -datapath_only 20 -from $snapshot_src -to $snapshot_dst
set preset_src [get_cells -hier -regexp {^preset_reg\[[0-9]+\]$}]
set preset_dst [get_cells -hier -regexp {^experiment/preset_reg\[[0-9]+\]$}]
if {[llength $preset_src]!=4 || [llength $preset_dst]!=4} {error "Preset held-data crossing changed"}
set_max_delay -datapath_only 20 -from $preset_src -to $preset_dst
# The locally generated PHY's own documented synchronizer entry stages.
set phy_sync [get_pins -hier -regexp {^phy/.*sync_reg\[0\]/D$}]
if {![llength $phy_sync]} {error "Generated PHY synchronizers not found"}
set_false_path -to $phy_sync
# Generated GT calibration helper synchronizer entry stages are audited in CDC.
set_property C_CLK_INPUT_FREQ_HZ 100000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets refclk]

# Generated PHY ships a synthetic 1 MHz clock on this BUFG output. It is
# driven by TXOUTCLK and can run at 250 MHz; use the fastest actual mode.
set startup_clock [get_pins -hier -filter {NAME =~ */phy_clk_i/bufg_gt_intclk/O}]
if {[llength $startup_clock]!=1} {error "Missing startup clock buffer"}
create_clock -name intclk -period 4 $startup_clock
