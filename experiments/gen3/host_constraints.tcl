# Fastest GTH-derived 250 MHz clock (Gen1 runs slower). No blanket asynchronous clock groups.
set gt [get_cells -hier -quiet -filter {REF_NAME == GTHE4_CHANNEL}]
set zu15eg [string match xczu15eg-ffvb1156-2-* [get_property PART [current_project]]]
set native_x2 [llength [get_cells -hier -quiet -filter {REF_NAME == gen3_native_x2 || ORIG_REF_NAME == gen3_native_x2}]]
if {$native_x2} {
 if {[info exists native_lane_sites]} {
  if {[llength $gt] != [llength $native_lane_sites]} {error "Wrong GTH channel count"}
  foreach channel $gt {
   if {![regexp {gen_gthe4_channel_inst\[([01])\]\.GTHE4_CHANNEL_PRIM_INST$} $channel -> lane]} {
    error "Cannot identify native lane for $channel"
   }
   set_property LOC [lindex $native_lane_sites $lane] $channel
  }
 } elseif {!$zu15eg || [lsort [get_property LOC $gt]] ne {GTHE4_CHANNEL_X1Y4 GTHE4_CHANNEL_X1Y5}} {
  error "Native x2 must use the generated DP0 and DP1 GT locations"
 }
 lassign {rx_cdc tx_cdc} rx_fifo tx_fifo
} else {
 set_property LOC [expr {[info exists native_lane_sites] ? [lindex $native_lane_sites 0] :
                         $zu15eg ? "GTHE4_CHANNEL_X1Y4" : "GTHE4_CHANNEL_X0Y15"}] $gt
 lassign {rx_crossing tx_crossing} rx_fifo tx_fifo
}
set rb [get_cells -hier -quiet -filter {REF_NAME == IBUFDS_GTE4}]
set_property LOC [expr {[info exists native_refclk_site] ? $native_refclk_site :
                        $zu15eg ? "GTHE4_COMMON_X1Y1" : "GTHE4_COMMON_X0Y3"}] $rb
set_property BEL IBUFDS0_GTHE4 $rb
# Native PHY XDC defines the 4 ns TXOUTCLK and rate mode.
set txclock [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]
if {[llength [get_clocks -of_objects $txclock]]!=1} {error "Missing unique native PCLK"}
set first [get_cells -hier -regexp {.*(ready_meta_reg\[[0-4]\]|idle_sync_reg\[0\]|request_sync_q_reg\[0\]|reply_sync_q_reg\[0\]|status_meta_q_reg\[[0-8]\]|phy_meta_q_reg\[[0-9]+\]|debug_meta_q_reg\[[0-9]+\]|heartbeat_sync_q_reg\[0\]|rate_meta_q_reg\[[0-2]\]|policy_sync_q_reg\[0\]|target_sync_q_reg\[0\]|idle_sync_q_reg\[0\])}]
set_false_path -to [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]
set release [get_cells -hier -regexp {.*release_q_reg\[[0-2]\]}]
set_false_path -to [get_pins -of_objects $release -filter {REF_PIN_NAME == CLR}]
# Bundled data hold until the synchronized round-trip acknowledgement. Limit
# physical delay/skew; synchronization latency provides additional settling.
set reqsrc [get_cells -hier -regexp {.*csr/request_payload_q_reg\[[0-9]+\]}]
set reqdst [get_cells -hier -regexp {.*csr/core_payload_q_reg\[[0-9]+\]}]
set repsrc [get_cells -hier -regexp {.*csr/reply_payload_q_reg\[[0-9]+\]}]
set repdst [get_cells -hier -regexp {.*csr/(result_q_reg\[[0-9]+\]|result_status_q_reg\[[0-2]\])}]
set_max_delay -datapath_only 8.000 -from $reqsrc -to $reqdst
set_bus_skew 8.000 -from $reqsrc -to $reqdst
set_max_delay -datapath_only 20.000 -from $repsrc -to $repdst
set_bus_skew 20.000 -from $repsrc -to $repdst
# Held reply data is qualified by the synchronized acknowledgement. Vivado
# optimizes result-status bit2's CE because timeout sets a constant zero;
# the same max-delay/skew and round-trip stability contract still applies.
# Use regexp for literal vector brackets in netlist object names.
set status_bit2 [get_pins -hier -regexp {.*csr/result_status_q_reg\[2\]/D}]
create_waiver -type CDC -id CDC-1 -to $status_bit2 -description {Held response mailbox payload captured only after three-stage reply toggle; max-delay/skew constrained, timeout sets bit2 zero; CSR ownership/stall/timeout simulation}
create_waiver -type CDC -id CDC-10 -to [get_pins -of_objects $release -filter {REF_PIN_NAME == CLR}] -description {Global/PERST reset assertion into three-stage clock-local release; stopped-clock reset test}
# Packet slots are published/returned with one-step Gray pointers. Bound both
# bit skew and flight time by the fastest source period (250MHz), without
# cutting the synchronizer chain or using asynchronous clock groups.
foreach fifo [list $rx_fifo $tx_fifo] {
 foreach {srcname dstname} {s_gray_q m_write_meta_q m_gray_q s_read_meta_q} {
  set src [get_cells -hier -regexp [format {.*%s/%s_reg\[[0-9]+\]} $fifo $srcname]]
  set dst [get_cells -hier -regexp [format {.*%s/%s_reg\[[0-9]+\]} $fifo $dstname]]
  if {[llength $src] != 3 || [llength $dst] != 3} {error "Missing packet CDC pointers $fifo"}
  set_max_delay -datapath_only 4.000 -from $src -to $dst
  set_bus_skew 4.000 -from $src -to $dst
 }
 set ram [get_cells -hier -regexp [format {.*%s/(data_q_reg|length_q_reg).*} $fifo] -filter {REF_NAME =~ RAMD.* || REF_NAME =~ RAMS.*}]
 set capture [get_cells -hier -regexp [format {.*%s/(prefetch_data_q_reg|read_length_q_reg)\[[0-9]+\]} $fifo]]
 set_max_delay -datapath_only 8.000 -from $ram -to $capture
 set_bus_skew 8.000 -from $ram -to $capture
}
# Command/response FIFO internals use AMD XPM scoped constraints. Do not
# retain the former custom Gray/RAM exceptions on these instances.
# These six independent link-clock reset-release chains share GLOBAL reset.
# No software PERST/rate reset reaches their pointer/ownership state.
set global_link_reset [get_pins -hier -regexp [format {.*(link_release_q_reg|command_crossing/l_release_q_reg|command_crossing/requests/m_release_q_reg|command_crossing/responses/s_release_q_reg|%s/s_release_q_reg|%s/m_release_q_reg)\[0\]/CLR} $rx_fifo $tx_fifo]]
create_waiver -type CDC -id CDC-11 -to $global_link_reset -description {Global reset independently releases clock-local ownership through three stages; no local reset or rate-change cancellation; stopped-clock/global-reset packet and command regressions}

# Matching host-domain GLOBAL reset release; command admission waits for both
# FIFO and owner release. Independent chains cannot discard accepted work.
set global_host_reset [get_pins -hier -regexp [format {.*(host_release_q_reg|mailbox_release_q_reg|command_crossing/h_release_q_reg|command_crossing/requests/s_release_q_reg|command_crossing/responses/m_release_q_reg|%s/m_release_q_reg|%s/s_release_q_reg)\[0\]/CLR} $rx_fifo $tx_fifo]]
create_waiver -type CDC -id CDC-11 -to $global_host_reset -description {Shared global async assertion and three-stage local release; FIFO and command ownership admission gated until ready; reset-skew regression}

# Native adapter source registers and dedicated entry stages.
if {$native_x2} {
 set native_first [get_pins -hier -regexp {.*root_port/(((rate_reset|fixed_rate_reset)\.)?release_sync_reg\[0\]|(reset_sync|enable_sync|ready_sync|power_sync)_reg\[0\]|idle_meta_reg\[[01]\])/D$}]
 if {[llength $native_first]!=7} {error "Native x2 adapter synchronizer count changed"}
 set native_reset [get_pins -hier -regexp {.*root_port/rate_reset\.release_sync_reg\[[0-2]\]/CLR$}]
 if {[llength $native_reset]} {
  if {[llength $native_reset]!=3} {error "Wrong x2 link reset release depth"}
  set_false_path -to $native_reset
  create_waiver -type CDC -id CDC-10 -to $native_reset -description {Global cold reset asserts without PCLK and releases through three link-clock stages}
 }
 set tx_fault_first [get_pins -hier -regexp {.*host_path/tx_fault_sync_reg\[0\]/D$}]
 if {[llength $tx_fault_first]!=1} {error "Missing TX fault synchronizer"}
 set_false_path -to $tx_fault_first
} else {
 set native_first [get_pins -hier -regexp {.*root_port/(reset_sync|enable_sync|release_sync|ready_sync|idle_sync)_reg\[0\]/D$}]
 if {[llength $native_first]!=5} {error "Native adapter synchronizer count changed"}
}
set_false_path -to $native_first
set phy_first [get_pins -hier -regexp {.*root_port/phy/.*sync_reg\[0\]/D$}]
if {![llength $phy_first]} {error "Native PHY synchronization missing"}
set_false_path -to $phy_first
set startup [get_pins -hier -filter {NAME =~ */phy_clk_i/bufg_gt_intclk/O}]
if {[llength $startup]!=1} {error "Missing native startup clock"}
set startup_name [get_property NAME [get_clocks -of_objects $startup]]
create_clock -name $startup_name -period 4 $startup
