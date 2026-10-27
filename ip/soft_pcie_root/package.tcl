# Build a self-contained local Vivado IP repository. No board access.
# Optional second argument changes the initial checkbox value only. Both PHY
# backends are included in one catalog definition and remain GUI-selectable.
if {[llength $argv] < 1 || [llength $argv] > 2} {error "Supply fresh output directory and optional default ENABLE_GEN3 (0 or 1)"}
set enable_gen3 0
if {[llength $argv] == 2} {set enable_gen3 [lindex $argv 1]}
if {$enable_gen3 ni {0 1}} {error "ENABLE_GEN3 must be 0 or 1"}
set root [file normalize [file join [file dirname [info script]] ../..]]
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output exists; use a fresh directory"}
file mkdir $output
exec python3 $root/scripts/host_sources.py capture $output/sources.json
set source $root/experiments/gen3
source $source/prepare_host_phy.tcl
create_project soft_pcie_package [file join $output project] -part xczu7ev-ffvc1156-2-e
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
source [file join $root ip soft_pcie_root create_gt.tcl]
# Import generated legacy RTL rather than an unconditional XCI subcore. Its
# constraints are selected by the same output-product template as the native PHY.
set legacy $output/project/soft_pcie_package.gen/sources_1/ip/pcie_gen1_gt
remove_files [get_files -all *.xci]
foreach dir {synth hdl} {read_verilog [glob $legacy/$dir/*.v]}
foreach dir {pcie_soft host management} {
 read_verilog -sv [glob [file join $root ip soft_pcie_root rtl $dir *.sv]]
}
file mkdir $output/native_sources
foreach dir {source synth ip_0/synth ip_0/hdl} {
 foreach f [glob $base/$dir/*.v] {
  set observed $output/observed_phy/[file tail $f]
  if {[file exists $observed]} {set original $observed} else {set original $f}
  set stream [open $original r];set text [read $stream];close $stream
  # Both generated PHYs ship same-named GT Wizard helpers. Keep the native
  # definitions private rather than relying on compile-order replacement.
  regsub -all {\mgtwizard_ultrascale_v[0-9_]+_[A-Za-z0-9_]+\M} $text {gen3_catalog_&} text
  set local $output/native_sources/gen3_catalog_[file tail $f]
  set stream [open $local w];puts -nonewline $stream $text;close $stream
  read_verilog $local
 }
}
foreach f [glob $source/gen3_*.sv] {
 if {[file tail $f] ne "gen3_eq_board.sv"} {read_verilog -sv $f}
}
set_property top soft_pcie_root [current_fileset]
update_compile_order -fileset sources_1
ipx::package_project -root_dir [file join $output core] -vendor soft-pcie.org -library user -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property name soft_pcie_root $core
set_property display_name {Soft PCIe Root Port (optional experimental Gen3)} $core
set_property description {Fabric PCIe root port with GTH PHY, AXI host/DDR bridge and MSI. No hard PCIe controller. Experimental single-endpoint configuration.} $core
set_property version 1.1 $core
set_property vendor_display_name {Soft PCIe contributors} $core
set_property supported_families {zynquplus Production} $core
set_property core_revision 1 $core
set_property value soft_pcie_root_v1_1 [ipx::get_user_parameters Component_Name -of_objects $core]
ipx::associate_bus_interfaces -busif S_AXI -clock aclk $core
ipx::associate_bus_interfaces -busif S_MEM -clock core_clk_o $core
ipx::associate_bus_interfaces -busif M_DDR -clock core_clk_o $core
foreach {name range} {S_AXI 4096 S_MEM 33554432} {
 set map [ipx::get_memory_maps $name -of_objects $core]
 if {![llength $map]} {error "Missing memory map $name"}
 set block [ipx::get_address_blocks -of_objects $map]
 set_property range $range $block
}
set param [ipx::get_user_parameters ENABLE_GEN3 -of_objects $core]
if {[llength $param]!=1} {error "Missing inferred ENABLE_GEN3 parameter"}
set_property -dict [list value_format bool value_resolve_type user value [expr {$enable_gen3 ? "true" : "false"}] display_name {Enable experimental Gen3}] $param
set model [ipx::get_hdl_parameters ENABLE_GEN3 -of_objects $core]
set_property value $enable_gen3 $model
set busparam [ipx::get_bus_parameters NUM_READ_OUTSTANDING -of_objects [ipx::get_bus_interfaces M_DDR -of_objects $core]]
set_property value_resolve_type dependent $busparam
set_property value_dependency {2 + 6 * spirit:decode(id('MODELPARAM_VALUE.ENABLE_GEN3'))} $busparam
# Generate only the selected PHY XDC at customization time. Preserve vendor
# constraints/notices, without targeting the backend that is not elaborated.
file mkdir $output/core/ttcl
set native_constraints $output/core/ttcl/phy_constraints.ttcl
set stream [open $native_constraints w]
puts $stream {<: setOutputDirectory "./" :>}
puts $stream {<: setFileName "[getComponentNameString]_phy" :>}
puts $stream {<: setFileExtension ".xdc" :>}
puts $stream {<: setFileProcessingOrder early :>}
puts $stream "<: if {\[getBooleanValue \"ENABLE_GEN3\"]} { :>"
foreach native_xdc [list $base/source/ip_pcie_phy.xdc $base/ip_0/synth/gen3_reference_phy_gt.xdc] {
 set input [open $native_xdc r];puts $stream [read $input];close $input
}
puts $stream "<: } else { :>"
set input [open $legacy/synth/pcie_gen1_gt.xdc r]
puts $stream [read $input];close $input
puts $stream "<: } :>"
close $stream
set group [ipx::get_file_groups xilinx_anylanguagesynthesis -of_objects $core]
set template [ipx::add_file ttcl/phy_constraints.ttcl $group]
set_property type ttcl $template
ipx::create_xgui_files $core
set gui [ipx::get_file_groups xilinx_xpgui -of_objects $core]
set guifile [lindex [ipx::get_files -of_objects $gui] 0]
file copy -force $root/ip/soft_pcie_root/xgui/soft_pcie_root.tcl $output/core/[get_property NAME $guifile]
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
exec python3 $root/scripts/host_sources.py check $output/sources.json
puts "SOFT_PCIE_IP_PACKAGED [file join $output core component.xml]"
