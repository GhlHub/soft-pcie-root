# SPDX-License-Identifier: Apache-2.0
# Apply the selected backend's CDC bounds separately to each root port.
set cdc_files [get_files -quiet *zu15eg_dual_cdc.tcl]
if {[llength $cdc_files] == 1} {
 set cdc_entry [get_property NAME $cdc_files]
} elseif {[llength $cdc_files] == 0 && [file tail [info script]] eq "zu15eg_dual_cdc.tcl"} {
 set cdc_entry [info script]
} else {error "Missing unique dual-port CDC entry file"}
set cdc_root [file normalize [file join [file dirname $cdc_entry] ../../..]]

proc constrain_zu15eg_port {root scope lane_sites refclk_site refclk_port legacy_link_clock} {
 set legacy_refclk [get_ports $refclk_port]
 try {
  current_instance $scope
  set gt_count [llength [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]]
  if {$gt_count ni {1 2} || [llength [get_cells -hier -filter {REF_NAME == IBUFDS_GTE4}]] != 1} {
   error "Wrong transceiver structure in $scope"
  }
  set native [get_cells -hier -quiet -filter {REF_NAME == gen3_native_root || ORIG_REF_NAME == gen3_native_root || REF_NAME == gen3_native_x2 || ORIG_REF_NAME == gen3_native_x2}]
  set legacy [get_cells -hier -quiet -filter {REF_NAME == pcie_soft_root_port || ORIG_REF_NAME == pcie_soft_root_port}]
  if {[llength $native] == 1 && ![llength $legacy]} {
   set native_lane_sites [lrange $lane_sites 0 [expr {$gt_count - 1}]]
   set native_refclk_site $refclk_site
   source [file join $root experiments gen3 host_constraints.tcl]
  } elseif {[llength $legacy] == 1 && ![llength $native] && $gt_count == 1} {
   set legacy_gt_site [lindex $lane_sites 0]
   set legacy_refclk_site $refclk_site
   source [file join $root examples zcu104 constraints zcu104_gen2_cdc.tcl]
  } else {
   error "Unexpected root backend in $scope"
  }
 } finally {current_instance}
}
constrain_zu15eg_port $cdc_root system_i/pcie {GTHE4_CHANNEL_X1Y4 GTHE4_CHANNEL_X1Y5} GTHE4_COMMON_X1Y1 refclk_p_i pcie_core
constrain_zu15eg_port $cdc_root system_i/pcie_b {GTHE4_CHANNEL_X1Y8 GTHE4_CHANNEL_X1Y9} GTHE4_COMMON_X1Y2 refclk_b_p_i pcie_b_core
