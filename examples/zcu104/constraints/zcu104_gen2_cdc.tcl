# Fastest GTH-derived 250 MHz clock (Gen1 runs slower). No blanket asynchronous clock groups.
set gt [get_cells -hier -quiet -filter {REF_NAME == GTHE4_CHANNEL}]
set_property LOC GTHE4_CHANNEL_X0Y15 $gt
set rb [get_cells -hier -quiet -filter {REF_NAME == IBUFDS_GTE4}]
set_property LOC GTHE4_COMMON_X0Y3 $rb
set_property BEL IBUFDS0_GTHE4 $rb
create_generated_clock -name pcie_core -source [get_ports refclk_p_i] -multiply_by 5 -divide_by 2 [get_pins -of_objects $gt -filter {REF_PIN_NAME == TXOUTCLK}]
set first [get_cells -hier -regexp {.*(ready_meta_reg\[[0-4]\]|idle_sync_reg\[0\]|request_sync_q_reg\[0\]|reply_sync_q_reg\[0\]|status_meta_q_reg\[[0-8]\]|phy_meta_q_reg\[[0-9]+\]|debug_meta_q_reg\[[0-9]+\]|heartbeat_sync_q_reg\[0\]|rate_meta_q_reg\[[0-2]\]|policy_sync_q_reg\[0\]|target_sync_q_reg\[0\]|idle_sync_q_reg\[0\])}]
set_false_path -to [get_pins -of_objects $first -filter {REF_PIN_NAME == D}]
set release [get_cells -hier -regexp {.*(release_q_reg|mailbox_release_q_reg|s_release_q_reg|m_release_q_reg|h_release_q_reg|l_release_q_reg|link_release_q_reg)\[[0-2]\]}]
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
set active [get_pins -hier -filter {NAME =~ *bit_synchronizer_gtwiz_reset_userclk_*_active_inst/i_in_meta_reg/D}]
create_waiver -type CDC -id CDC-11 -to $active -description {AMD GTH TX/RX helpers independently synchronize common user-clock-active through five stages}
# Read-only diagnostic taps deliberately sample non-atomic levels. Decoded
# ready/present/LTSSM outputs may glitch during transitions; they are never
# used for control or admission. Read stable repeated samples for diagnosis.
set diagnostic_decodes [get_pins -hier -regexp {.*csr/phy_meta_q_reg\[(7|11|14|15)\]/D}]
create_waiver -type CDC -id CDC-10 -to $diagnostic_decodes -description {Read-only two-stage informational ready/present/idle/detect samples; transition codes and pulses are not guaranteed; no control or admission fanout}
set diagnostic_active [get_pins -hier -regexp {.*csr/phy_meta_q_reg\[4\]/D}]
create_waiver -type CDC -id CDC-11 -to $diagnostic_active -description {Independent read-only two-stage TX clock-active observation; no reconvergence into vendor reset control or request admission}

# Packet slots are published/returned with one-step Gray pointers. Bound both
# bit skew and flight time by the fastest source period (250MHz), without
# cutting the synchronizer chain or using asynchronous clock groups.
# Held packet crossing: rx_crossing
set src [get_cells -hier -regexp {.*rx_crossing/s_gray_q_reg\[[0-9]+\]}]
set dst [get_cells -hier -regexp {.*rx_crossing/m_write_meta_q_reg\[[0-9]+\]}]
set_max_delay -datapath_only 4.000 -from $src -to $dst
set_bus_skew 4.000 -from $src -to $dst
set src [get_cells -hier -regexp {.*rx_crossing/m_gray_q_reg\[[0-9]+\]}]
set dst [get_cells -hier -regexp {.*rx_crossing/s_read_meta_q_reg\[[0-9]+\]}]
set_max_delay -datapath_only 4.000 -from $src -to $dst
set_bus_skew 4.000 -from $src -to $dst
set ram [get_cells -hier -regexp {.*rx_crossing/(data_q_reg|length_q_reg).*} -filter {REF_NAME =~ RAMD.* || REF_NAME =~ RAMS.*}]
set capture [get_cells -hier -regexp {.*rx_crossing/(prefetch_data_q_reg|read_length_q_reg)\[[0-9]+\]}]
set_max_delay -datapath_only 8.000 -from $ram -to $capture
set_bus_skew 8.000 -from $ram -to $capture
# Held packet crossing: tx_crossing
set src [get_cells -hier -regexp {.*tx_crossing/s_gray_q_reg\[[0-9]+\]}]
set dst [get_cells -hier -regexp {.*tx_crossing/m_write_meta_q_reg\[[0-9]+\]}]
set_max_delay -datapath_only 4.000 -from $src -to $dst
set_bus_skew 4.000 -from $src -to $dst
set src [get_cells -hier -regexp {.*tx_crossing/m_gray_q_reg\[[0-9]+\]}]
set dst [get_cells -hier -regexp {.*tx_crossing/s_read_meta_q_reg\[[0-9]+\]}]
set_max_delay -datapath_only 4.000 -from $src -to $dst
set_bus_skew 4.000 -from $src -to $dst
set ram [get_cells -hier -regexp {.*tx_crossing/(data_q_reg|length_q_reg).*} -filter {REF_NAME =~ RAMD.* || REF_NAME =~ RAMS.*}]
set capture [get_cells -hier -regexp {.*tx_crossing/(prefetch_data_q_reg|read_length_q_reg)\[[0-9]+\]}]
set_max_delay -datapath_only 8.000 -from $ram -to $capture
set_bus_skew 8.000 -from $ram -to $capture
# Command/response FIFO internals use AMD XPM scoped constraints. Do not
# retain the former custom Gray/RAM exceptions on these instances.
# These six independent link-clock reset-release chains share GLOBAL reset.
# No software PERST/rate reset reaches their pointer/ownership state.
set global_link_reset [get_pins -hier -regexp {.*(link_release_q_reg|command_crossing/l_release_q_reg|command_crossing/requests/m_release_q_reg|command_crossing/responses/s_release_q_reg|rx_crossing/s_release_q_reg|tx_crossing/m_release_q_reg)\[0\]/CLR}]
create_waiver -type CDC -id CDC-11 -to $global_link_reset -description {Global reset independently releases clock-local ownership through three stages; no local reset or rate-change cancellation; stopped-clock/global-reset packet and command regressions}

# Matching host-domain GLOBAL reset release; command admission waits for both
# FIFO and owner release. Independent chains cannot discard accepted work.
set global_host_reset [get_pins -hier -regexp {.*(mailbox_release_q_reg|command_crossing/h_release_q_reg|command_crossing/requests/s_release_q_reg|command_crossing/responses/m_release_q_reg|rx_crossing/m_release_q_reg|tx_crossing/s_release_q_reg)\[0\]/CLR}]
create_waiver -type CDC -id CDC-11 -to $global_host_reset -description {Shared global async assertion and three-stage local release; FIFO and command ownership admission gated until ready; reset-skew regression}
