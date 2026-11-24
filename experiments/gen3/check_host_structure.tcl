set x2_native [llength [get_cells -hier -quiet -filter {REF_NAME == gen3_native_x2 || ORIG_REF_NAME == gen3_native_x2}]]
set x2_gen2 [llength [get_cells -hier -quiet -filter {REF_NAME == gen3_native_x2_rate || ORIG_REF_NAME == gen3_native_x2_rate}]]
set x2_gen3 [llength [get_cells -hier -quiet -filter {REF_NAME == gen3_x2_port || ORIG_REF_NAME == gen3_x2_port}]]
if {$x2_gen3} {
 if {$x2_native != 1 || $x2_gen2 != 1 || $x2_gen3 != 1} {error "Wrong Gen3 x2 native backend count"}
 foreach expected {gen3_x2_initial_eq gen3_multilane_eq gen3_x2_post_port gen3_link_layer_x2 gen3_x2_receive} {
  if {[llength [get_cells -hier -quiet -filter "REF_NAME == $expected || ORIG_REF_NAME == $expected"]] != 1} {
   error "Missing integrated Gen3 x2 block $expected"
  }
 }
}
if {[info exists host_scope]} {current_instance}
set hp_index [expr {[info exists host_hp_index] ? $host_hp_index : 2}]
set addr_width [expr {[info exists host_ddr_addr_width] ? $host_ddr_addr_width : 36}]
set hp_port HP[expr {$hp_index - 2}]
set ps [get_cells -hier -filter {REF_NAME == PS8}]
if {[llength $ps]!=1} {error "Expected one PS8"}
foreach pin [list SAXIGP${hp_index}RCLK SAXIGP${hp_index}WCLK] {
 set hpclk [get_pins -of_objects $ps -filter "REF_PIN_NAME == $pin"]
 if {[llength $hpclk]!=1} {error "Missing $hp_port clock $pin"}
 set clocks [get_clocks -of_objects $hpclk]
 if {[llength $clocks]!=1 || abs([get_property PERIOD $clocks]-8.0)>0.001} {error "$hp_port must be clocked at 125 MHz: $clocks"}
}
foreach field [list SAXIGP${hp_index}WDATA SAXIGP${hp_index}RDATA] {
 set pins [get_pins -of_objects $ps -filter "REF_PIN_NAME =~ ${field}*"]
 if {[llength $pins]!=128} {error "$hp_port data width wrong for $field: [llength $pins]"}
}
if {[info exists host_full_ddr] && $host_full_ddr} {
 foreach channel {AW AR} {
  set field [format {SAXIGP%s%sADDR[35]} $hp_index $channel]
  set pin [get_pins -of_objects $ps -filter "REF_PIN_NAME == $field"]
  set net [get_nets -quiet -of_objects $pin]
  if {[llength $pin] != 1 || [llength $net] != 1 || [get_property TYPE $net] in {GROUND POWER}} {
   error "DDR bank bit is missing or constant on $field"
  }
 }
 puts "GEN3_HIGH_DDR_STRUCTURE_PASS ${hp_port} read_and_write_bank_bit35"
}
if {[info exists host_scope]} {current_instance $host_scope}
puts "GEN3_HOST_STRUCTURE_PASS ${hp_port}_128bit_125MHz DDR_completer_present"

set packet_fifos [expr {$x2_native ? [list rx_cdc tx_cdc] : [list rx_crossing tx_crossing]}]
foreach fifo $packet_fifos {
 foreach name {s_gray_q m_gray_q s_read_meta_q s_read_mid_q s_read_sync_q m_write_meta_q m_write_mid_q m_write_sync_q} {
  set ptr [get_cells -hier -regexp [format {.*%s/%s_reg\[[0-9]+\]} $fifo $name]]
  if {[llength $ptr]!=3} {error "Wrong packet CDC pointer width/stage $fifo $name"}
 }
 set cdc_capture [get_cells -hier -regexp [format {.*%s/m_data_o_reg\[[0-9]+\]} $fifo]]
 if {$x2_native} {
  if {[llength $cdc_capture]<128} {error "Missing wide registered packet CDC payload $fifo"}
  set length_capture [get_cells -hier -regexp [format {.*%s/read_length_q_reg\[[0-9]+\]} $fifo]]
  if {[llength $length_capture]!=5} {error "Missing clock-local packet length capture $fifo"}
 } else {
  set packet_ram [get_cells -hier -filter "(NAME =~ */$fifo/data_q_reg || NAME =~ *.$fifo/data_q_reg) && REF_NAME =~ RAMB*"]
  if {[llength $packet_ram]!=1} {error "Missing clocked packet RAM $fifo"}
  set bus_width 72
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
  if {[llength $length_capture]!=6} {error "Missing clock-local packet length capture $fifo"}
 }
}
puts "PACKET_CDC_STRUCTURE_PASS two_packet_FIFOs registered_payload Gray_pointers_three_stages"

lassign $packet_fifos rx_fifo tx_fifo
set host_reset_pins [get_pins -hier -regexp [format {.*(host_release_q_reg|mailbox_release_q_reg|command_crossing/h_release_q_reg|command_crossing/requests/s_release_q_reg|command_crossing/responses/m_release_q_reg|%s/m_release_q_reg|%s/s_release_q_reg)\[0\]/CLR} $rx_fifo $tx_fifo]]
if {[llength $host_reset_pins] != 6 + $x2_native} {error "Global host reset waiver scope changed"}

# Actual ownership counters must survive technology mapping: two writes/eight reads.
set bridge [expr {$x2_native ? "host_path/bridge" : "ddr"}]
set read_bits [expr {4 + $x2_native}]
foreach {name bits} [list write_out_q 2 read_pending_q $read_bits read_slots_q $read_bits] {
 set owner [get_cells -hier -regexp [format {.*%s/%s_reg\[[0-9]+\]} $bridge $name]]
 if {[llength $owner]!=$bits} {error "Wrong DDR owner width $name"}
}
puts "DDR_OWNERSHIP_STRUCTURE_PASS write_B_owners read_R_owners completion_slots"
set writer [get_cells -hier -regexp [format {.*%s/FSM_onehot_write_state_q_reg\[[0-2]\]$} $bridge]]
if {[llength $writer]!=3} {error "Missing independent DDR write execution state"}
set write_address [get_cells -hier -regexp [format {.*%s/write_address_q_reg\[[0-9]+\]$} $bridge]]
# The exact register names exclude physical replicas of the alignment bit.
if {[llength $write_address] != $addr_width - 2} {error "Missing independent DWORD-aligned DDR write address"}
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
 set expected [expr {$fifo eq "requests" || ($x2_native && !$x2_gen2) ? 8.0 : 4.0}]
 if {![string match {*-datapath_only*} [get_property EXCEPTION $path]]} {error "XPM RAM path lost datapath-only constraint $fifo"}
 if {abs([get_property REQUIREMENT $path]-$expected)>0.001} {error "Wrong XPM max-delay bound $fifo"}
}
puts "COMMAND_XPM_STRUCTURE_PASS two_macros depth16 three_stage_pointers reset_busy_guards scoped_RAM_delay"

set gt [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]
if {[llength $gt]!=1 + $x2_native} {error "Wrong native GTH count"}
if {[llength [get_cells -hier -quiet -filter {REF_NAME =~ PCIE*}]]} {error "Unexpected PCIe hard controller"}
if {$x2_native} {
 set expected_lanes [expr {[info exists gt_sites] ? $gt_sites : {GTHE4_CHANNEL_X1Y4 GTHE4_CHANNEL_X1Y5}}]
 if {[lsort [get_property LOC $gt]] ne $expected_lanes} {error "Wrong x2 lane locations"}
 set pclk [get_pins -hier -filter {NAME =~ */phy_clk_i/bufg_gt_pclk/O}]
 set clocks [get_clocks -of_objects $pclk]
 set period [expr {$x2_gen2 ? 4.0 : 8.0}]
 if {[llength $pclk]!=1 || [llength $clocks]!=1 || abs([get_property PERIOD $clocks]-$period)>0.001} {
  error "Native x2 must use one shared $period ns PCLK for timing"
 }
 set native_first [get_pins -hier -regexp {.*root_port/(((rate_reset|fixed_rate_reset)\.)?release_sync_reg\[0\]|(reset_sync|enable_sync|ready_sync|power_sync)_reg\[0\]|idle_meta_reg\[[01]\])/D$}]
 if {[llength $native_first]!=7} {error "Native x2 synchronizer scope changed"}
 if {$x2_gen2} {
  set rate_policy [get_pins -hier -regexp {.*root_port/programmable_rate\.policy_sync_q_reg\[0\]/D$}]
  if {[llength $rate_policy]!=1 || ![get_property ASYNC_REG [get_cells -of_objects $rate_policy]]} {
   error "Missing Gen2 x2 rate policy synchronizer"
  }
 }
} else {
 set native_first [get_pins -hier -regexp {.*root_port/(reset_sync|enable_sync|release_sync|ready_sync|idle_sync)_reg\[0\]/D$}]
 if {[llength $native_first]!=5} {error "Native synchronizer scope changed"}
}
foreach pin $native_first {
 if {![get_property ASYNC_REG [get_cells -of_objects $pin]]} {error "Missing ASYNC_REG $pin"}
}
puts "GEN3_NATIVE_STRUCTURE_PASS [llength $gt] GTH [llength $native_first] entry synchronizers"
