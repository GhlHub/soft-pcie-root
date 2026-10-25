# Experimental FMC ZCU104 FMC lane0. PCIe PHY mode enables receiver detection;
# it does not instantiate a PCIe controller/hard block.
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name pcie_gen1_gt
set ip [get_ips pcie_gen1_gt]
set_property -dict [list CONFIG.CHANNEL_ENABLE X0Y15 CONFIG.TX_MASTER_CHANNEL X0Y15 CONFIG.RX_MASTER_CHANNEL X0Y15 \
 CONFIG.TX_LINE_RATE 2.5 CONFIG.RX_LINE_RATE 2.5 CONFIG.TX_PLL_TYPE CPLL CONFIG.RX_PLL_TYPE CPLL \
 CONFIG.TX_REFCLK_FREQUENCY 100 CONFIG.RX_REFCLK_FREQUENCY 100 \
 CONFIG.TX_DATA_ENCODING 8B10B CONFIG.RX_DATA_DECODING 8B10B \
 CONFIG.TX_USER_DATA_WIDTH 16 CONFIG.RX_USER_DATA_WIDTH 16 CONFIG.TX_INT_DATA_WIDTH 20 CONFIG.RX_INT_DATA_WIDTH 20 \
 CONFIG.RX_COMMA_M_ENABLE true CONFIG.RX_COMMA_P_ENABLE true CONFIG.RX_COMMA_MASK 1111111111 \
 CONFIG.RX_COMMA_M_VAL 1010000011 CONFIG.RX_COMMA_P_VAL 0101111100 \
 CONFIG.LOCATE_TX_USER_CLOCKING CORE CONFIG.LOCATE_RX_USER_CLOCKING EXAMPLE_DESIGN \
 CONFIG.PCIE_ENABLE true CONFIG.PCIE_CORECLK_FREQ 250 CONFIG.PCIE_USERCLK_FREQ 250 \
 CONFIG.LOCATE_RESET_CONTROLLER CORE CONFIG.FREERUN_FREQUENCY 50] $ip
# Shared TX/RX 125MHz user clock. The RX elastic buffer corrects recovered
# frequency drift by adding/removing SKP only, never COM (which seeds LFSRs).
set_property -dict [list CONFIG.RX_CC_NUM_SEQ 1 CONFIG.RX_CC_LEN_SEQ 1 CONFIG.RX_CC_PERIODICITY 1538 \
 CONFIG.RX_CC_KEEP_IDLE ENABLE CONFIG.RX_CC_MASK_0_0 false] $ip
set_property -dict [list CONFIG.RX_CC_VAL_0_0 00011100 CONFIG.RX_CC_K_0_0 true] $ip
set_property CONFIG.ENABLE_OPTIONAL_PORTS {cplllock_out cpllfreqlock_in pcierstidle_in rxoutclk_out rxresetdone_out txresetdone_out rxbyteisaligned_out rxcommadet_out txdetectrx_in txelecidle_in txpd_in rxpd_in rxelecidle_out rxstatus_out phystatus_out rxpolarity_in rxbufstatus_out rxrate_in txrate_in pcierateidle_out txdeemph_in} $ip
foreach p {C_TX_USRCLK_FREQUENCY C_TX_USRCLK2_FREQUENCY C_RX_USRCLK_FREQUENCY C_RX_USRCLK2_FREQUENCY} {
 if {abs([get_property CONFIG.$p $ip]-125.0)>0.001} {error "Unexpected $p"}
}
generate_target all $ip
