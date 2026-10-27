# SPDX-License-Identifier: Apache-2.0
# One board CDC entry point follows the catalog checkbox after elaboration.
# Keep the reviewed per-backend scopes separate; never mix their clock models.
# Vivado's project constraint loader may leave info script empty or pointing
# at its caller. Prefer the registered file; direct OOC sourcing has no entry.
set cdc_files [get_files -quiet *zcu104_cdc.tcl]
if {[llength $cdc_files]==1} {
 set cdc_entry [get_property NAME $cdc_files]
} elseif {[llength $cdc_files]==0 && [file tail [info script]] eq "zcu104_cdc.tcl"} {
 set cdc_entry [info script]
} else {error "Missing unique board CDC entry file"}
set cdc_directory [file dirname $cdc_entry]
set native [get_cells -hier -quiet -filter {REF_NAME == gen3_native_root || ORIG_REF_NAME == gen3_native_root}]
set legacy [get_cells -hier -quiet -filter {REF_NAME == pcie_soft_root_port || ORIG_REF_NAME == pcie_soft_root_port}]
if {[llength $native]+[llength $legacy]!=1} {error "Expected exactly one selected PCIe root backend"}
if {[llength $native]} {
 source [file join $cdc_directory ../../../experiments/gen3/host_constraints.tcl]
} else {
 source [file join $cdc_directory zcu104_gen2_cdc.tcl]
}
