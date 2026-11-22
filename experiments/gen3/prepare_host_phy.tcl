# SPDX-License-Identifier: Apache-2.0
# Called by the unified packager; generates AMD sources only in its fresh output.
# The reference part exposes the PHY generator and has both required GTH sites.
# Synthesis and routing of the assembled design use the actual board's part.
if {![info exists native_width]} {set native_width 1}
set native_name [expr {$native_width == 2 ? "gen3_reference_phy_x2" : "gen3_reference_phy"}]
set phy_project phy_reference
create_project $phy_project $output/$phy_project -part xczu9eg-ffvb1156-2-e
create_ip -name pcie_phy -vendor xilinx.com -library ip -module_name $native_name
set_property -dict [list CONFIG.gt_type GTH CONFIG.phy_lane X$native_width CONFIG.phy_max_speed 8.0_GT/s \
    CONFIG.phy_refclk_freq 100_MHz CONFIG.phy_userclk_freq 250_MHz CONFIG.phy_coreclk_freq 250_MHz \
    CONFIG.tx_preset 4 CONFIG.aspm No_ASPM CONFIG.phy_async_en false \
    CONFIG.lane0_gt_bank GTH_Quad_$gt_bank CONFIG.lane0_gt_location GTHE4_CHANNEL_$gt_channel \
    CONFIG.refclk1_location Bank_${gt_bank}_MGTREFCLK0] [get_ips $native_name]
generate_target all [get_ips $native_name]
set base $output/$phy_project/$phy_project.gen/sources_1/ip/$native_name
close_project
set instrument_args [list --startup-reference --module-name $native_name]
if {$native_width == 2} {lappend instrument_args --shared-cdr-hold}
exec python3 $source/instrument_eq_phy.py $base $output/observed_phy {*}$instrument_args
