# SPDX-License-Identifier: Apache-2.0
# One board CDC entry point follows the catalog checkbox after elaboration.
# Keep the reviewed per-backend scopes separate; never mix their clock models.
set native [get_cells -hier -quiet -filter {REF_NAME == gen3_native_root || ORIG_REF_NAME == gen3_native_root}]
set legacy [get_cells -hier -quiet -filter {REF_NAME == pcie_soft_root_port || ORIG_REF_NAME == pcie_soft_root_port}]
if {[llength $native]+[llength $legacy]!=1} {error "Expected exactly one selected PCIe root backend"}
if {[llength $native]} {
 source [file join [file dirname [info script]] ../../../experiments/gen3/host_constraints.tcl]
} else {
 source [file join [file dirname [info script]] zcu104_gen2_cdc.tcl]
}
