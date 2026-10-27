# SPDX-License-Identifier: Apache-2.0
if {$argc!=1} {error "Supply a fresh package output"}
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output must be fresh"}
file mkdir $output
set source [file dirname [file normalize [info script]]]
set root [file normalize $source/../..]
exec python3 $source/host_sources.py capture $output/sources.json
create_project phy_reference $output/phy_reference -part xczu9eg-ffvb1156-2-e
create_ip -name pcie_phy -vendor xilinx.com -library ip -module_name gen3_reference_phy
set_property -dict [list CONFIG.gt_type GTH CONFIG.phy_lane X1 CONFIG.phy_max_speed 8.0_GT/s \
    CONFIG.phy_refclk_freq 100_MHz CONFIG.phy_userclk_freq 250_MHz CONFIG.phy_coreclk_freq 250_MHz \
    CONFIG.tx_preset 4 CONFIG.aspm No_ASPM CONFIG.phy_async_en false \
    CONFIG.lane0_gt_bank GTH_Quad_130 CONFIG.lane0_gt_location GTHE4_CHANNEL_X0Y15 \
    CONFIG.refclk1_location Bank_130_MGTREFCLK0] [get_ips gen3_reference_phy]
generate_target all [get_ips gen3_reference_phy]
set base $output/phy_reference/phy_reference.gen/sources_1/ip/gen3_reference_phy
close_project
exec python3 $source/instrument_eq_phy.py $base $output/observed_phy --startup-reference

create_project gen3_host_package $output/project -part xczu7ev-ffvc1156-2-e
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
foreach dir {source synth ip_0/synth ip_0/hdl} {
    foreach f [glob $base/$dir/*.v] {
        set observed $output/observed_phy/[file tail $f]
        if {[file exists $observed]} {read_verilog $observed} else {read_verilog $f}
    }
}
foreach f [glob $source/gen3_*.sv] {
    if {[file tail $f] ne "gen3_eq_board.sv"} {read_verilog -sv $f}
}
foreach dir {pcie_soft host management} {read_verilog -sv [glob $root/ip/soft_pcie_root/rtl/$dir/*.sv]}
exec python3 $source/host_sources.py shell $output/gen3_soft_pcie_root.sv
read_verilog -sv $output/gen3_soft_pcie_root.sv
read_xdc $base/source/ip_pcie_phy.xdc
read_xdc $base/ip_0/synth/gen3_reference_phy_gt.xdc
set_property top gen3_soft_pcie_root [current_fileset]
update_compile_order -fileset sources_1
ipx::package_project -root_dir $output/core -vendor soft-pcie.org -library experimental -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property name gen3_soft_pcie_root $core
set_property display_name {Experimental native Gen3 x1 root} $core
set_property version 0.1 $core
set_property supported_families {zynquplus Production} $core
set_property core_revision 1 $core
ipx::associate_bus_interfaces -busif S_AXI -clock aclk $core
ipx::associate_bus_interfaces -busif S_MEM -clock core_clk_o $core
ipx::associate_bus_interfaces -busif M_DDR -clock core_clk_o $core
foreach {name range} {S_AXI 4096 S_MEM 33554432} {
 set map [ipx::get_memory_maps $name -of_objects $core]
 if {[llength $map]!=1} {error "Missing memory map $name"}
 set_property range $range [ipx::get_address_blocks -of_objects $map]
}
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
exec python3 $source/host_sources.py check $output/sources.json
puts "EXPERIMENTAL_GEN3_PACKAGE $output/core/component.xml"
