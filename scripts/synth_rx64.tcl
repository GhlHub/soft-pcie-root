# SPDX-License-Identifier: Apache-2.0
# Out-of-context resource/BRAM checks only, not board timing or physical proof.
if {$argc!=1} {error "Usage: synth_rx64.tcl fresh-output-directory"}
set root [file normalize [file join [file dirname [info script]] ..]]
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Fresh output required"}
file mkdir $output
foreach {top generic} {pcie_ddr_bridge {RX_DWORDS=2} pcie_cdc_packet {WIDTH=65 WORDS=32 SLOTS=4} pcie_rx_pack {}} {
 create_project -in_memory -part xczu7ev-ffvc1156-2-e
 read_verilog -sv $root/ip/soft_pcie_root/rtl/host/$top.sv
 synth_design -top $top -part xczu7ev-ffvc1156-2-e -mode out_of_context -generic $generic
 report_utilization -hierarchical -file $output/$top-utilization.rpt
 write_checkpoint $output/$top.dcp
 if {$top eq "pcie_cdc_packet"} {
  set ram [get_cells -hier -filter {REF_NAME =~ RAMB*}]
  if {[llength $ram]!=1} {error "Expected one packet BRAM"}
  if {[get_property READ_WIDTH_A $ram]!=72 || [get_property WRITE_WIDTH_B $ram]!=72} {error "RX64 BRAM width"}
  puts "RX64_BRAM_PASS $ram"
 }
 close_project
}
puts "RX64_SYNTH_PASS"
