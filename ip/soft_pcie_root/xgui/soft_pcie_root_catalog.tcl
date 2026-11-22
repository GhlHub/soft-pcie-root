# SPDX-License-Identifier: Apache-2.0
proc init_gui {IPINST} {
 ipgui::add_param $IPINST -name Component_Name
 set page [ipgui::add_page $IPINST -name Configuration]
 set mode [ipgui::add_param $IPINST -name PCIE_MODE -parent $page -widget comboBox]
 set_property display_name {PCIe mode} $mode
 set_property tooltip {Build-time generation and lane count. Both x2 modes require the ZU15EG two-lane FMC pin mapping.} $mode
 set preset [ipgui::add_param $IPINST -name GEN3_TX_PRESET -parent $page]
 set_property tooltip {Initial Gen3 transmit preset. The peer may request a different preset during equalization.} $preset
}

proc validate_PARAM_VALUE.PCIE_MODE {PARAM_VALUE.PCIE_MODE} {
 if {[get_property value ${PARAM_VALUE.PCIE_MODE}] in {0 1 2 3}} {return true}
 return false
}

proc update_PARAM_VALUE.GEN3_TX_PRESET {PARAM_VALUE.GEN3_TX_PRESET PARAM_VALUE.PCIE_MODE} {
 set enabled [expr {[get_property value ${PARAM_VALUE.PCIE_MODE}] in {2 3} ? "true" : "false"}]
 set_property enabled $enabled ${PARAM_VALUE.GEN3_TX_PRESET}
}
proc validate_PARAM_VALUE.GEN3_TX_PRESET {PARAM_VALUE.GEN3_TX_PRESET} {
 set value [get_property value ${PARAM_VALUE.GEN3_TX_PRESET}]
 if {[string is integer -strict $value] && $value >= 0 && $value <= 10} {return true}
 return false
}
proc update_MODELPARAM_VALUE.GEN3_TX_PRESET {MODELPARAM_VALUE.GEN3_TX_PRESET PARAM_VALUE.GEN3_TX_PRESET} {
 set_property value [get_property value ${PARAM_VALUE.GEN3_TX_PRESET}] ${MODELPARAM_VALUE.GEN3_TX_PRESET}
}

# The tested Gen1/Gen2 x2 backend also uses the native PHY. Its Gen3 rate
# engine is controlled separately by X2_GEN3_BRINGUP.
proc update_MODELPARAM_VALUE.ENABLE_GEN3 {MODELPARAM_VALUE.ENABLE_GEN3 PARAM_VALUE.PCIE_MODE} {
 set_property value [expr {[get_property value ${PARAM_VALUE.PCIE_MODE}] != 0}] ${MODELPARAM_VALUE.ENABLE_GEN3}
}
proc update_MODELPARAM_VALUE.LINK_WIDTH {MODELPARAM_VALUE.LINK_WIDTH PARAM_VALUE.PCIE_MODE} {
 set_property value [expr {[get_property value ${PARAM_VALUE.PCIE_MODE}] in {1 3} ? 2 : 1}] ${MODELPARAM_VALUE.LINK_WIDTH}
}
proc update_MODELPARAM_VALUE.X2_GEN2_BRINGUP {MODELPARAM_VALUE.X2_GEN2_BRINGUP PARAM_VALUE.PCIE_MODE} {
 set_property value [expr {[get_property value ${PARAM_VALUE.PCIE_MODE}] == 1}] ${MODELPARAM_VALUE.X2_GEN2_BRINGUP}
}
proc update_MODELPARAM_VALUE.X2_GEN3_BRINGUP {MODELPARAM_VALUE.X2_GEN3_BRINGUP PARAM_VALUE.PCIE_MODE} {
 set_property value [expr {[get_property value ${PARAM_VALUE.PCIE_MODE}] == 3}] ${MODELPARAM_VALUE.X2_GEN3_BRINGUP}
}
