# SPDX-License-Identifier: Apache-2.0
# Isolated resource/inference check; not routed board timing or physical proof.
if {$argc!=1} {error "Usage: synth_prefetch.tcl fresh-output"}
set root [file normalize [file join [file dirname [info script]] ..]]
set output [file normalize [lindex $argv 0]]
if {[file exists $output]} {error "Fresh output required"}
file mkdir $output
foreach {name top generic} {
 gen2_bridge pcie_ddr_bridge {RX_DWORDS=1 TX_DWORDS=1 READ_SLOTS=2 PIPELINED_READS=0}
 gen3_bridge pcie_ddr_bridge {RX_DWORDS=2 TX_DWORDS=2 READ_SLOTS=8 PIPELINED_READS=1}
 gen2_rx pcie_cdc_packet {WIDTH=33 WORDS=64 SLOTS=4}
 gen2_tx pcie_cdc_packet {WIDTH=36 WORDS=64 SLOTS=4}
 gen3_rx pcie_cdc_packet {WIDTH=65 WORDS=32 SLOTS=4}
 gen3_tx pcie_cdc_packet {WIDTH=68 WORDS=32 SLOTS=4}
} {
 create_project -in_memory -part xczu7ev-ffvc1156-2-e
 read_verilog -sv $root/ip/soft_pcie_root/rtl/host/$top.sv
 synth_design -top $top -part xczu7ev-ffvc1156-2-e -mode out_of_context -generic $generic
 report_utilization -hierarchical -file $output/$name-utilization.rpt
 write_checkpoint $output/$name.dcp
 if {$top eq "pcie_cdc_packet"} {
  set ram [get_cells -hier -filter {REF_NAME =~ RAMB*}]
  set width [expr {[string match gen3_* $name]?72:36}]
  if {[llength $ram]!=1} {error "Expected one packet RAM: $name"}
  if {[get_property READ_WIDTH_A $ram]!=$width || [get_property WRITE_WIDTH_B $ram]!=$width} {error "Wrong packet RAM geometry: $name"}
  puts "PREFETCH_PACKET_RAM_PASS $name width=$width"
 }
 close_project
}
puts "PREFETCH_SYNTH_PASS"
