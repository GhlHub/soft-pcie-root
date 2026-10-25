# Standalone vendor secure-IP rate-switch regression; never programs a board.
if {[llength $argv]!=1} {error "Supply fresh simulation output directory"}
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Simulation output must be fresh"}
file mkdir $out
create_project gen2_phy [file join $out project] -part xczu7ev-ffvc1156-2-e
source [file join $root ip soft_pcie_root create_gt.tcl]
add_files -fileset sim_1 [list [file join $root ip soft_pcie_root rtl pcie_soft pcie_soft_gth.sv] \
 [file join $root ip soft_pcie_root rtl pcie_soft pcie_soft_rate_control.sv] [file join $root tests pcie_soft tb_phy_runtime.sv]]
set_property top tb_phy_runtime [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
launch_simulation
run 1ms
if {[get_value -radix unsigned /tb_phy_runtime/passed]!=1} {error "Production PHY rate regression failed"}
puts "GEN2_VENDOR_PHY_REGRESSION_PASS"
close_sim
exit
