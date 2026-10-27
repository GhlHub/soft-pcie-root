# SPDX-License-Identifier: Apache-2.0
# Called by the unified packager; generates AMD sources only in its fresh output.
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
