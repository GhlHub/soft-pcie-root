# Build a self-contained local Vivado IP repository. No board access.
if {[llength $argv] != 1} {error "Supply a fresh output directory"}
set root [file normalize [file join [file dirname [info script]] ../..]]
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output exists; use a fresh directory"}
file mkdir $output
create_project soft_pcie_package [file join $output project] -part xczu7ev-ffvc1156-2-e
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
source [file join $root ip soft_pcie_root create_gt.tcl]
set_property GENERATE_SYNTH_CHECKPOINT false [get_files -all *.xci]
foreach dir {pcie_soft host management} {
 read_verilog -sv [glob [file join $root ip soft_pcie_root rtl $dir *.sv]]
}
set_property top soft_pcie_root [current_fileset]
update_compile_order -fileset sources_1
ipx::package_project -root_dir [file join $output core] -vendor soft-pcie.org -library user -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property name soft_pcie_root $core
set_property display_name {Soft PCIe Root Port (Gen1/Gen2 x1)} $core
set_property description {Fabric PCIe root port with GTH PHY, AXI host/DDR bridge and MSI. No hard PCIe controller. Experimental single-endpoint configuration.} $core
set_property version 1.0 $core
set_property vendor_display_name {Soft PCIe contributors} $core
set_property supported_families {zynquplus Production} $core
set_property core_revision 1 $core
ipx::associate_bus_interfaces -busif S_AXI -clock aclk $core
ipx::associate_bus_interfaces -busif S_MEM -clock core_clk_o $core
ipx::associate_bus_interfaces -busif M_DDR -clock core_clk_o $core
foreach {name range} {S_AXI 4096 S_MEM 33554432} {
 set map [ipx::get_memory_maps $name -of_objects $core]
 if {![llength $map]} {error "Missing memory map $name"}
 set block [ipx::get_address_blocks -of_objects $map]
 set_property range $range $block
}
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
puts "SOFT_PCIE_IP_PACKAGED [file join $output core component.xml]"
