# SPDX-License-Identifier: Apache-2.0
# Compatibility entry point: one catalog core, with its initial Gen3 checkbox on.
if {$argc!=1} {error "Supply a fresh package output"}
set argv [list [lindex $argv 0] 1]
set argc 2
source [file join [file dirname [info script]] ../../ip/soft_pcie_root/package.tcl]
