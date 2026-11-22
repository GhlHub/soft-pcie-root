# SPDX-License-Identifier: Apache-2.0
# J25 GBTCLK0. The GT's bank 228 channel 0 supplies J25 DP0.
set_property PACKAGE_PIN L8 [get_ports refclk_p_i]
set_property PACKAGE_PIN L7 [get_ports refclk_n_i]
create_clock -name pcie_refclk -period 10.000 [get_ports refclk_p_i]
# J25 G6/LA00_P_CC and H13/LA07_P. Both are active high on OP063.
set_property -dict {PACKAGE_PIN R10 IOSTANDARD LVCMOS18} [get_ports perst_a_o]
set_property -dict {PACKAGE_PIN M11 IOSTANDARD LVCMOS18} [get_ports disable_ssd2_power_o]
set_false_path -to [get_ports {perst_a_o disable_ssd2_power_o}]
