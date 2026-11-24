# SPDX-License-Identifier: Apache-2.0
# Add the second independent root on FMC DP4/DP5.
create_zu15eg_root pcie_b $catalog $backend $enable_gen3 $link_width
set_property CONFIG.PSU__SAXIGP3__DATA_WIDTH 128 [get_bd_cells ps]
connect_bd_net [get_bd_pins management_clock/clk_out1] [get_bd_pins pcie_b/aclk]
connect_bd_net [get_bd_pins management_clock/clk_out2] [get_bd_pins pcie_b/host_clk_i]
connect_bd_net [get_bd_pins reset/peripheral_aresetn] [get_bd_pins pcie_b/aresetn]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/ps/M_AXI_HPM0_FPD" Slave "/pcie_b/S_AXI" Clk_master "/management_clock/clk_out1 (50 MHz)" Clk_slave "/management_clock/clk_out1 (50 MHz)" Clk_xbar "/management_clock/clk_out1 (50 MHz)" intc_ip "Auto"} [get_bd_intf_pins pcie_b/S_AXI]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/ps/M_AXI_HPM0_FPD" Slave "/pcie_b/S_MEM" Clk_master "/management_clock/clk_out1 (50 MHz)" Clk_slave "/pcie_b/core_clk_o (125 MHz)" Clk_xbar "/management_clock/clk_out1 (50 MHz)" intc_ip "Auto"} [get_bd_intf_pins pcie_b/S_MEM]
connect_bd_net [get_bd_pins pcie_b/core_clk_o] [get_bd_pins ps/saxihp1_fpd_aclk]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/pcie_b/M_DDR" Slave "/ps/S_AXI_HP1_FPD" Clk_master "/pcie_b/core_clk_o (125 MHz)" Clk_slave "/pcie_b/core_clk_o (125 MHz)" Clk_xbar "/pcie_b/core_clk_o (125 MHz)" intc_ip "New AXI Interconnect"} [get_bd_intf_pins ps/S_AXI_HP1_FPD]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat pcie_irqs
set_property CONFIG.NUM_PORTS 2 [get_bd_cells pcie_irqs]
connect_bd_net [get_bd_pins pcie/irq_o] [get_bd_pins pcie_irqs/In0]
connect_bd_net [get_bd_pins pcie_b/irq_o] [get_bd_pins pcie_irqs/In1]
connect_bd_net [get_bd_pins pcie_irqs/dout] [get_bd_pins ps/pl_ps_irq0]
foreach {pin port direction} {
 refclk_p_i refclk_b_p_i I refclk_n_i refclk_b_n_i I
 rx_p_i rx_b_p_i I rx_n_i rx_b_n_i I
 tx_p_o tx_b_p_o O tx_n_o tx_b_n_o O
} {
 set width_args {}
 if {$x2_stage && ![string match refclk_* $pin]} {set width_args {-from 1 -to 0}}
 create_bd_port -dir $direction {*}$width_args $port
 connect_bd_net [get_bd_ports $port] [get_bd_pins pcie_b/$pin]
}
assign_bd_address -offset 0xA0001000 -range 4K -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs pcie_b/S_AXI/reg0] -force
assign_bd_address -offset 0xA4000000 -range 32M -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs pcie_b/S_MEM/reg0] -force
assign_zu15eg_ddr pcie_b 1 $ddr_addr_width $full_ddr
