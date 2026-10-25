# Run on an open technology-mapped ZCU104 host design. Checks have ordinary
# Tcl evaluation here, independently of Vivado's restricted XDC parser.
set first [get_cells -hier -regexp {.*(ready_meta_reg\[[0-4]\]|idle_sync_reg\[0\]|request_sync_q_reg\[0\]|reply_sync_q_reg\[0\]|status_meta_q_reg\[[0-8]\]|phy_meta_q_reg\[[0-9]+\]|debug_meta_q_reg\[[0-9]+\]|heartbeat_sync_q_reg\[0\]|rate_meta_q_reg\[[0-2]\]|policy_sync_q_reg\[0\]|target_sync_q_reg\[0\]|idle_sync_q_reg\[0\])}]
if {[llength $first]!=179} {error "Host synchronizer first-stage count changed"}
set release [get_cells -hier -regexp {.*(release_q_reg|mailbox_release_q_reg|s_release_q_reg|m_release_q_reg|h_release_q_reg|l_release_q_reg|link_release_q_reg)\[[0-2]\]}]
if {[llength $release]!=39} {error "Host reset-release chain count changed"}
foreach pattern {{.*csr/request_payload_q_reg\[[0-9]+\]} {.*csr/core_payload_q_reg\[[0-9]+\]} {.*csr/reply_payload_q_reg\[[0-9]+\]} {.*csr/result_q_reg\[[0-9]+\]}} {
 if {![llength [get_cells -hier -regexp $pattern]]} {error "Missing live mailbox payload $pattern"}
}
if {[llength [get_cells -hier -regexp {.*host/dma_enable_o_reg}]]!=1} {error "Missing host DMA admission register"}
if {![llength [get_cells -hier -regexp {.*ddr/.*state_q_reg.*}]]} {error "Missing DDR bridge state"}
set ps [get_cells -hier -filter {REF_NAME == PS8}]
if {[llength $ps]!=1} {error "Expected one PS8"}
foreach pin {SAXIGP2RCLK SAXIGP2WCLK} {
 set hpclk [get_pins -of_objects $ps -filter "REF_PIN_NAME == $pin"]
 if {[llength $hpclk]!=1} {error "Missing HP0 clock $pin"}
 set clocks [get_clocks -of_objects $hpclk]
 if {[llength $clocks]!=1 || abs([get_property PERIOD $clocks]-8.0)>0.001} {error "HP0 must be clocked at125MHz: $clocks"}
}
foreach field {SAXIGP2WDATA SAXIGP2RDATA} {
 set pins [get_pins -of_objects $ps -filter "REF_PIN_NAME =~ ${field}*"]
 if {[llength $pins]!=128} {error "HP0 data width wrong for $field: [llength $pins]"}
}
puts "HOST_STRUCTURE_PASS first_stage179 reset_release39 HP0_128bit_125MHz DDR_completer_present"

foreach {fifo width} {rx_crossing 3 tx_crossing 3} {
 foreach name {s_gray_q m_gray_q s_read_meta_q s_read_mid_q s_read_sync_q m_write_meta_q m_write_mid_q m_write_sync_q} {
  set ptr [get_cells -hier -regexp [format {.*%s/%s_reg\[[0-9]+\]} $fifo $name]]
  if {[llength $ptr]!=$width} {error "Wrong packet CDC pointer width/stage $fifo $name"}
 }
 set cdc_capture [get_cells -hier -regexp [format {.*%s/m_data_o_reg\[[0-9]+\]} $fifo]]
 if {[string match command_crossing/* $fifo]} {
  if {![llength $cdc_capture]} {error "Missing registered command CDC payload $fifo"}
 } else {
  set packet_ram [get_cells -hier -filter "NAME =~ */$fifo/data_q_reg && REF_NAME =~ RAMB*"]
  if {[llength $packet_ram]!=1} {error "Missing clocked packet RAM $fifo"}
  set bus_width [expr {$fifo eq "rx_crossing"?36:72}]
  if {[get_property READ_WIDTH_A $packet_ram]!=$bus_width || [get_property WRITE_WIDTH_B $packet_ram]!=$bus_width ||
      [get_property WRITE_WIDTH_A $packet_ram]!=0 || [get_property READ_WIDTH_B $packet_ram]!=0} {
   error "Wrong simple-dual-port packet RAM geometry $fifo"
  }
  foreach {port rx_period tx_period} {CLKARDCLK 8.0 4.0 CLKBWRCLK 4.0 8.0} {
   set packet_clock [get_clocks -of_objects [get_pins -of_objects $packet_ram -filter "REF_PIN_NAME == $port"]]
   set expected_period [expr {$fifo eq "rx_crossing"?$rx_period:$tx_period}]
   if {[llength $packet_clock]!=1 || abs([get_property PERIOD $packet_clock]-$expected_period)>0.001} {
    error "Wrong packet RAM read/write clock $fifo $port"
   }
  }
  set length_capture [get_cells -hier -regexp [format {.*%s/read_length_q_reg\[[0-9]+\]} $fifo]]
  if {[llength $length_capture]!=7} {error "Missing clock-local packet length capture $fifo"}
 }
}
puts "PACKET_CDC_STRUCTURE_PASS two_packet_FIFOs registered_payload Gray_pointers_three_stages"

set host_reset_pins [get_pins -hier -regexp {.*(mailbox_release_q_reg|command_crossing/h_release_q_reg|command_crossing/requests/s_release_q_reg|command_crossing/responses/m_release_q_reg|rx_crossing/m_release_q_reg|tx_crossing/s_release_q_reg)\[0\]/CLR}]
if {[llength $host_reset_pins]!=6} {error "Global host reset waiver scope changed"}

# Actual two-burst ownership counters must survive technology mapping.
foreach name {write_out_q read_pending_q read_slots_q} {
 set owner [get_cells -hier -regexp [format {.*ddr/%s_reg\[[0-1]\]} $name]]
 if {[llength $owner]!=2} {error "Missing two-burst DDR owner $name"}
}
puts "DDR_TWO_OUTSTANDING_STRUCTURE_PASS write_B_owners read_R_owners completion_slots"
set writer [get_cells -hier -regexp {.*ddr/FSM_onehot_write_state_q_reg\[[0-2]\]$}]
if {[llength $writer]!=3} {error "Missing independent DDR write execution state"}
set write_address [get_cells -hier -regexp {.*ddr/write_address_q_reg\[[0-9]+\]$}]
# Exclude the physical replicas of the alignment bit from the 30-bit count.
if {[llength $write_address] != 30} {error "Missing independent DWORD-aligned DDR write address"}
puts "DDR_WRITE_PIPELINE_STRUCTURE_PASS independent_writer held_address preparation_state"


# Check the real AMD macro, its three-stage pointer synchronizers, reset-busy
# guards and effective vendor data-path constraints; no custom RAM exceptions.
foreach fifo {requests responses} {
 set macro [get_cells -hier -filter "NAME =~ */command_crossing/$fifo/fifo && ORIG_REF_NAME == xpm_fifo_async"]
 if {[llength $macro]!=1} {error "Missing AMD command FIFO $fifo"}
 set width [expr {$fifo eq "requests"?119:35}]
 foreach {prop expected_value} [list FIFO_WRITE_DEPTH 16 CDC_SYNC_STAGES 3 RELATED_CLOCKS 0 P_FIFO_MEMORY_TYPE 1 P_READ_MODE 1 FIFO_READ_LATENCY 0 WRITE_DATA_WIDTH $width READ_DATA_WIDTH $width] {
  if {[get_property $prop $macro]!=$expected_value} {error "Wrong XPM parameter $fifo $prop"}
 }
 foreach direction {wr rd} {
  foreach stage {0 1 2} {
   set sync [get_cells -hier -regexp [format {.*command_crossing/%s/fifo/.*gen_cdc_pntr\.%s_pntr_cdc_inst/dest_graysync_ff_reg\[%d\]\[[0-3]\]} $fifo $direction $stage]]
   if {[llength $sync]!=4} {error "Wrong XPM pointer synchronization $fifo $direction $stage"}
   foreach ff $sync {
    if {![get_property ASYNC_REG $ff]} {error "XPM pointer missing ASYNC_REG $ff"}
   }
  }
 }
 set reset_ff [get_cells -hier -regexp [format {.*command_crossing/%s/fifo_reset_q_reg} $fifo]]
 if {[llength $reset_ff]!=1 || [get_property REF_NAME $reset_ff] ne "FDRE"} {error "Missing synchronous XPM reset $fifo"}
 foreach domain {s m} {
  set seen [get_cells -hier -regexp [format {.*command_crossing/%s/%s_reset_seen_q_reg} $fifo $domain]]
  if {[llength $seen]!=1} {error "Missing XPM reset-busy observation $fifo $domain"}
 }
 set ram [get_cells -hier -filter "NAME =~ */command_crossing/$fifo/fifo/* && REF_NAME =~ RAMD*"]
 set capture [get_cells -hier -filter "NAME =~ */command_crossing/$fifo/fifo/*doutb_reg_reg* && REF_NAME == FDRE"]
 if {![llength $ram] || ![llength $capture]} {error "Missing XPM distributed RAM/read registers $fifo"}
 set path [get_timing_paths -from $ram -to $capture -max_paths 1]
 if {[llength $path]!=1} {error "Missing timed XPM data path $fifo"}
 set expected [expr {$fifo eq "requests"?8.0:4.0}]
 if {![string match {*-datapath_only*} [get_property EXCEPTION $path]]} {error "XPM RAM path lost datapath-only constraint $fifo"}
 if {abs([get_property REQUIREMENT $path]-$expected)>0.001} {error "Wrong XPM max-delay bound $fifo"}
}
puts "COMMAND_XPM_STRUCTURE_PASS two_macros depth16 three_stage_pointers reset_busy_guards scoped_RAM_delay"
