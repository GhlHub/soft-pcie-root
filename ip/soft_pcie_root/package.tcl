# Build a self-contained local Vivado IP repository. No board access.
# The ZU15EG catalog contains the legacy PHY and both native PHY widths.
# The original x1 and fixed-stage entry points still generate version 1.1.
if {[llength $argv] < 1 || [llength $argv] > 4} {
 error "Supply fresh output directory, optional default ENABLE_GEN3 (0 or 1), board (zcu104 or zu15eg), and optional catalog, gen1-x2, gen2-x2, gen3-x2, dual-x1, dual-gen3, dual-<x2 stage> or dual-gen3-x2-full-ddr profile"
}
set enable_gen3 0
if {[llength $argv] >= 2} {set enable_gen3 [lindex $argv 1]}
if {$enable_gen3 ni {0 1}} {error "ENABLE_GEN3 must be 0 or 1"}
set board zcu104
if {[llength $argv] >= 3} {set board [lindex $argv 2]}
set native_width 1
set stage ""
set board_placed 0
if {[llength $argv] == 4} {
 set stage [lindex $argv 3]
 if {[string match dual-* $stage]} {
  if {$board ne "zu15eg"} {error "Dual-root packages require zu15eg"}
  set board_placed 1
  set stage [string range $stage 5 end]
  if {$stage eq "gen3-x2-full-ddr"} {
   set stage gen3-x2
  }
 }
 if {$board_placed && $stage in {x1 gen3}} {
  if {$enable_gen3 != ($stage eq "gen3")} {error "Use ENABLE_GEN3=0 for dual-x1 or 1 for dual-gen3"}
  set stage ""
 } elseif {!$board_placed && $stage eq "catalog"} {
  if {$board ne "zu15eg" || $enable_gen3} {error "Use 0 zu15eg $stage"}
 } elseif {$stage ni {gen1-x2 gen2-x2 gen3-x2} || $board ne "zu15eg" || !$enable_gen3} {
  error "The x2 stages require zu15eg and ENABLE_GEN3=1"
 } else {
  set native_width 2
 }
}
set catalog [expr {$stage eq "catalog"}]
set version [expr {$catalog ? "1.2" : "1.1"}]
set widths [expr {$catalog ? {1 2} : [list $native_width]}]
switch -- $board {
 zcu104 {
  set package_part xczu7ev-ffvc1156-2-e
  set gt_channel X0Y15
  set gt_bank 130
 }
 zu15eg {
  set package_part xczu15eg-ffvb1156-2-i
  set gt_channel X1Y4
  set gt_bank 228
 }
 default {error "Unsupported packaging board: $board"}
}
set root [file normalize [file join [file dirname [info script]] ../..]]
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Output exists; use a fresh directory"}
file mkdir $output
exec python3 $root/scripts/host_sources.py capture $output/sources.json
set source $root/experiments/gen3
proc package_phy {output source native_width gt_bank gt_channel} {
 file mkdir $output
 source $source/prepare_host_phy.tcl
 return [list $base $native_name $output/observed_phy]
}
foreach width $widths {
 set phy_output [expr {$catalog ? "$output/native_x$width" : $output}]
 set phys($width) [package_phy $phy_output $source $width $gt_bank $gt_channel]
}
create_project soft_pcie_package [file join $output project] -part $package_part
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
foreach width $widths {
 lassign $phys($width) base native_name observed_dir
 set prefix [expr {$catalog ? "gen3_catalog_x${width}_" : "gen3_catalog_"}]
 foreach dir {source synth ip_0/synth ip_0/hdl} {
  foreach f [glob $base/$dir/*.v] {
   set observed $observed_dir/[file tail $f]
   if {[file exists $observed]} {set original $observed} else {set original $f}
   set stream [open $original r];set text [read $stream];close $stream
   # The generated PHYs share GT Wizard helper names. Isolate each set.
   regsub -all {\mgtwizard_ultrascale_v[0-9_]+_[A-Za-z0-9_]+\M} $text ${prefix}& text
   set local $output/native_sources/$prefix[file tail $f]
   set stream [open $local w];puts -nonewline $stream $text;close $stream
   read_verilog $local
  }
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
if {$catalog} {
 set_property display_name {Soft PCIe Root Port (ZU15EG)} $core
 set_property description {Single-endpoint fabric PCIe root port with selectable Gen1/Gen2 and Gen3 x1/x2 modes, GTH PHY, AXI host/DDR bridge and MSI.} $core
} else {
 set_property display_name {Soft PCIe Root Port (optional experimental Gen3)} $core
 set_property description {Fabric PCIe root port with GTH PHY, AXI host/DDR bridge and MSI. No hard PCIe controller. Experimental single-endpoint configuration.} $core
}
set_property version $version $core
set_property vendor_display_name {Soft PCIe contributors} $core
set_property supported_families {zynquplus Production} $core
set_property core_revision 1 $core
set_property value soft_pcie_root_v[string map {. _} $version] [ipx::get_user_parameters Component_Name -of_objects $core]
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
set width [ipx::get_user_parameters LINK_WIDTH -of_objects $core]
if {[llength $width]!=1} {error "Missing inferred LINK_WIDTH parameter"}
set_property -dict [list value_format long value_resolve_type user value $native_width display_name {Link width (x2 training development)} value_validation_type range_long value_validation_range_minimum 1 value_validation_range_maximum 2] $width
set_property value $native_width [ipx::get_hdl_parameters LINK_WIDTH -of_objects $core]
# Use the RTL address-width default for all catalog modes and board profiles.
set ddr_model [ipx::get_hdl_parameters DDR_ADDR_WIDTH -of_objects $core]
set ddr_addr_width [get_property value $ddr_model]
set_property value $ddr_addr_width [ipx::get_user_parameters DDR_ADDR_WIDTH -of_objects $core]
# A fixed package aperture avoids the 4 KiB placeholder Vivado infers for a
# parameterized AXI address port. Board address assignments select the RAM.
set ddr_space [ipx::get_address_spaces M_DDR -of_objects $core]
set_property -dict [list RANGE_RESOLVE_TYPE immediate RANGE_DEPENDENCY {} RANGE_FORMAT bitString \
 RANGE_BIT_STRING_LENGTH [expr {$ddr_addr_width + 1}] RANGE [format 0x%X [expr {1 << $ddr_addr_width}]]] $ddr_space
foreach {mode parameter} {gen1-x2 X2_GEN1_BRINGUP gen2-x2 X2_GEN2_BRINGUP gen3-x2 X2_GEN3_BRINGUP} {
 set selected [expr {$stage eq $mode}]
 set_property value $selected [ipx::get_user_parameters $parameter -of_objects $core]
 set_property value $selected [ipx::get_hdl_parameters $parameter -of_objects $core]
}
set preset [ipx::get_user_parameters GEN3_TX_PRESET -of_objects $core]
if {[llength $preset]!=1} {error "Missing inferred GEN3_TX_PRESET parameter"}
set_property -dict [list value_format long value_resolve_type user value 4 display_name {Gen3 TX preset (0-10)} value_validation_type range_long value_validation_range_minimum 0 value_validation_range_maximum 10] $preset
set_property value 4 [ipx::get_hdl_parameters GEN3_TX_PRESET -of_objects $core]
set gui_source soft_pcie_root.tcl
if {$catalog} {
 # One user choice controls the existing RTL backend and port parameters.
 set mode [ipx::add_user_parameter PCIE_MODE $core]
 set_property -dict [list display_name {PCIe mode} value_format long value_resolve_type user \
  value_validation_type pairs value_validation_pairs {{Gen1/Gen2 x1} 0 {Gen1/Gen2 x2} 1 {Gen3 x1} 2 {Gen3 x2} 3} \
  value 0] $mode
 set gui_source soft_pcie_root_catalog.tcl
}
set busparam [ipx::get_bus_parameters NUM_READ_OUTSTANDING -of_objects [ipx::get_bus_interfaces M_DDR -of_objects $core]]
set_property value_resolve_type dependent $busparam
set_property value_dependency {2 + 6 * spirit:decode(id('MODELPARAM_VALUE.ENABLE_GEN3')) + 8 * (spirit:decode(id('MODELPARAM_VALUE.X2_GEN1_BRINGUP')) + spirit:decode(id('MODELPARAM_VALUE.X2_GEN2_BRINGUP')) + spirit:decode(id('MODELPARAM_VALUE.X2_GEN3_BRINGUP')))} $busparam
# Generate only the selected PHY XDC at customization time. Preserve vendor
# constraints/notices, without targeting the backend that is not elaborated.
file mkdir $output/core/ttcl
set native_constraints $output/core/ttcl/phy_constraints.ttcl
set stream [open $native_constraints w]
puts $stream {<: setOutputDirectory "./" :>}
puts $stream {<: setFileName "[getComponentNameString]_phy" :>}
puts $stream {<: setFileExtension ".xdc" :>}
puts $stream {<: setFileProcessingOrder early :>}
if {$board_placed} {puts $stream {<: set component [getComponentNameString] :>}}
proc write_native_constraints {stream phy stage {placement_width 0}} {
 lassign $phy base native_name
 foreach native_xdc [list $base/source/ip_pcie_phy.xdc $base/ip_0/synth/${native_name}_gt.xdc] {
  set input [open $native_xdc r];set text [read $input];close $input
  if {$stage in {gen1-x2 gen2-x2} && [file tail $native_xdc] eq "ip_pcie_phy.xdc"} {
   # Use the fastest rate of the legacy bring-up stage during implementation.
   if {[regsub -all {set_case_analysis 1 (\[get_pins -filter \{REF_PIN_NAME=~[TR]XRATE\[1\]\})} $text {set_case_analysis 0 \1} text] != 2 ||
       ($stage eq "gen1-x2" && [regsub {create_clock -name txoutclk -period 4 } $text {create_clock -name txoutclk -period 8 } text] != 1) ||
       ($stage eq "gen2-x2" && [regsub -all {set_case_analysis 0 (\[get_pins -filter \{REF_PIN_NAME=~[TR]XRATE\[0\]\})} $text {set_case_analysis 1 \1} text] != 2)} {
    error "Unexpected native PHY rate constraints"
   }
  }
  if {$placement_width} {
   if {[file tail $native_xdc] eq "ip_pcie_phy.xdc"} {
    if {[regsub -all {create_clock -name (intclk|txoutclk) } $text {create_clock -name <=:$component:>_\1 } text] != 2} {
     error "Expected a startup clock and a link clock in the native PHY constraints"
    }
   } elseif {[regsub -all -line {^[ \t]*set_property LOC GTHE4_CHANNEL_[^\n]+\n} $text {} text] != $placement_width} {
    error "Expected $placement_width native GTH channel placements"
   }
  }
  puts $stream $text
 }
}
if {$catalog} {
 puts $stream {<: set native [getIntValue "ENABLE_GEN3"] :>}
 puts $stream {<: set width [getIntValue "LINK_WIDTH"] :>}
 puts $stream {<: set gen2_x2 [getIntValue "X2_GEN2_BRINGUP"] :>}
 puts $stream "<: if {\$gen2_x2} \{ :>"
 write_native_constraints $stream $phys(2) gen2-x2
 puts $stream "<: \} elseif {\$native && \$width == 1} \{ :>"
 write_native_constraints $stream $phys(1) gen3
 puts $stream "<: \} elseif {\$native && \$width == 2} \{ :>"
 write_native_constraints $stream $phys(2) gen3-x2
} else {
 puts $stream {<: set native [getBooleanValue "ENABLE_GEN3"] :>}
 puts $stream "<: if {\$native} \{ :>"
 write_native_constraints $stream $phys($native_width) $stage [expr {$board_placed ? $native_width : 0}]
}
puts $stream "<: \} else \{ :>"
set input [open $legacy/synth/pcie_gen1_gt.xdc r]
set legacy_xdc [read $input]
close $input
# The dual-root board constraints place each instance on a different GTH.
# Keep all of the wizard's other constraints, including CPLL calibration.
if {$board_placed && [regsub -all -line {^[ \t]*set_property LOC GTHE4_CHANNEL_[^\n]+\n} $legacy_xdc {} legacy_xdc] != 1} {
 error "Expected exactly one legacy GT channel placement"
}
puts $stream $legacy_xdc
puts $stream "<: \} :>"
close $stream
set group [ipx::get_file_groups xilinx_anylanguagesynthesis -of_objects $core]
set template [ipx::add_file ttcl/phy_constraints.ttcl $group]
set_property type ttcl $template
ipx::create_xgui_files $core
set gui [ipx::get_file_groups xilinx_xpgui -of_objects $core]
set guifile [lindex [ipx::get_files -of_objects $gui] 0]
file copy -force $root/ip/soft_pcie_root/xgui/$gui_source $output/core/[get_property NAME $guifile]
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
exec python3 $root/scripts/host_sources.py check $output/sources.json
set target_file [open [file join $output target-part.txt] w]
puts $target_file $package_part
close $target_file
set width_file [open [file join $output native-width.txt] w]
puts $width_file $widths
close $width_file
if {$board_placed} {
 set placement_file [open [file join $output board-placed-gth.txt] w]
 puts $placement_file [lindex $argv 3]
 close $placement_file
}
puts "SOFT_PCIE_IP_PACKAGED [file join $output core component.xml]"
