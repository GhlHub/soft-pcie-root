# SPDX-License-Identifier: Apache-2.0
# DP0/DP1 and GBTCLK0 only. The top leaves FMC adapter sidebands undriven.
set_property PACKAGE_PIN L8 [get_ports refclk_p_i]
set_property PACKAGE_PIN L7 [get_ports refclk_n_i]
create_clock -name pcie_refclk -period 10.000 [get_ports refclk_p_i]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
