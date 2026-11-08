# SPDX-License-Identifier: Apache-2.0
# Metadata-only check of actual root RTL parameter inference and XGUI propagation.
# No generated PHY, output products, synthesis, implementation or board access.
if {[llength $argv] != 1} {error "Supply a fresh output directory"}
set root [file normalize [file join [file dirname [info script]] ..]]
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output exists; use a fresh directory"}
file mkdir $output
create_project width_metadata $output/project -part xczu7ev-ffvc1156-2-e
read_verilog -sv $root/ip/soft_pcie_root/rtl/management/soft_pcie_root.sv
set_property top soft_pcie_root [current_fileset]
ipx::package_project -root_dir $output/core -vendor soft-pcie.org -library user -import_files -set_current true
set core [ipx::current_core]
# Execute the production width metadata block, so this cannot drift into a
# parallel test-only definition of the range or parameter name.
set f [open $root/ip/soft_pcie_root/package.tcl r]
set packaging [read $f]
close $f
set begin [string first {set width [ipx::get_user_parameters LINK_WIDTH} $packaging]
set end [string first {set preset [ipx::get_user_parameters GEN3_TX_PRESET} $packaging $begin]
if {$begin < 0 || $end <= $begin} {error "Cannot locate production width metadata block"}
eval [string range $packaging $begin [expr {$end-1}]]
source $root/ip/soft_pcie_root/xgui/soft_pcie_root.tcl
set user [ipx::get_user_parameters LINK_WIDTH -of_objects $core]
set model [ipx::get_hdl_parameters LINK_WIDTH -of_objects $core]
if {[get_property value $user] != 1 || [get_property value $model] != 1} {error "x1 default changed"}
if {[get_property value_validation_range_minimum $user] != 1 ||
    [get_property value_validation_range_maximum $user] != 2} {error "Wrong lane-count range"}
foreach choice {2 1} {
 set_property value $choice $user
 update_MODELPARAM_VALUE.LINK_WIDTH $model $user
 if {[get_property value $model] != $choice} {error "XGUI did not propagate LINK_WIDTH"}
}
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
puts "PASS LINK_WIDTH metadata inference, range, x1 default and real-object GUI propagation"
close_project
