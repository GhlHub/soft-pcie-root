# SPDX-License-Identifier: Apache-2.0
# Reuse the single-port structure and CDC audit for each root independently.
set audit_root [file normalize [file join [file dirname [info script]] ../..]]
set audit_addr_width [expr {[info exists ddr_addr_width] ? $ddr_addr_width : 36}]
set audit_full_ddr [expr {[info exists full_ddr] && $full_ddr}]
proc check_zu15eg_port {root host_scope host_hp_index host_ddr_addr_width host_full_ddr lane_sites refclk_site} {
 try {
  current_instance $host_scope
  set gt [get_cells -hier -quiet -filter {REF_NAME == GTHE4_CHANNEL}]
  set rb [get_cells -hier -quiet -filter {REF_NAME == IBUFDS_GTE4}]
  set gt_sites [lrange $lane_sites 0 [expr {[llength $gt] - 1}]]
  if {[llength $gt] ni {1 2} || [lsort [get_property LOC $gt]] ne $gt_sites ||
      [llength $rb] != 1 || [get_property LOC $rb] ne $refclk_site ||
      ![string match */IBUFDS0_GTHE4 [get_bels -of_objects $rb]]} {
   error "Wrong lane or reference buffer for $host_scope"
  }
  set native [get_cells -hier -quiet -filter {REF_NAME == gen3_native_root || ORIG_REF_NAME == gen3_native_root || REF_NAME == gen3_native_x2 || ORIG_REF_NAME == gen3_native_x2}]
  if {[llength $native] == 1} {
   source [file join $root experiments gen3 check_host_structure.tcl]
  } elseif {[llength $gt] == 1 && ![llength $native]} {
   source [file join $root examples zcu104 check_structure.tcl]
  } else {
   error "Unexpected native backend count for $host_scope"
  }
 } finally {current_instance}
}
check_zu15eg_port $audit_root system_i/pcie 2 $audit_addr_width $audit_full_ddr {GTHE4_CHANNEL_X1Y4 GTHE4_CHANNEL_X1Y5} GTHE4_COMMON_X1Y1
check_zu15eg_port $audit_root system_i/pcie_b 3 $audit_addr_width $audit_full_ddr {GTHE4_CHANNEL_X1Y8 GTHE4_CHANNEL_X1Y9} GTHE4_COMMON_X1Y2
puts ZU15EG_DUAL_STRUCTURE_PASS
