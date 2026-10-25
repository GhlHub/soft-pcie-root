# OP063 SSD1, ZCU104 reference constraints at pinned Opsero revision.
set_property PACKAGE_PIN V8 [get_ports refclk_p_i]
set_property PACKAGE_PIN V7 [get_ports refclk_n_i]
create_clock -name pcie_refclk -period 10.000 [get_ports refclk_p_i]
set_property PACKAGE_PIN F17 [get_ports perst_a_o]
set_property PACKAGE_PIN J16 [get_ports disable_ssd2_power_o]
set_property IOSTANDARD LVCMOS18 [get_ports {perst_a_o disable_ssd2_power_o}]
# Sideband reset/power controls are asynchronous card controls, not a sampled
# data interface. Their durations are enforced in RTL at 50 MHz.
set_false_path -to [get_ports {perst_a_o disable_ssd2_power_o}]
