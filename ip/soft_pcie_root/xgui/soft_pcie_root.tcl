# SPDX-License-Identifier: Apache-2.0
proc init_gui {IPINST} {
 ipgui::add_param $IPINST -name Component_Name
 set page [ipgui::add_page $IPINST -name Configuration]
 set enable [ipgui::add_param $IPINST -name ENABLE_GEN3 -parent $page -widget checkBox]
 set_property display_name {Enable experimental Gen3} $enable
 set_property tooltip {Unchecked: Gen1/Gen2, 32-bit host packet paths, 2 x 64-byte prefetch slots. Checked: experimental Gen3, 64-bit paths, 8 slots. Gen3 requires further stabilization. DDR AXI remains 64-bit/125 MHz. Use the matching example constraints; this is not a runtime switch.} $enable
 set preset [ipgui::add_param $IPINST -name GEN3_TX_PRESET -parent $page]
 set_property display_name {Gen3 TX preset (0-10)} $preset
 set_property tooltip {Initial TX preset applied before Gen3 rate change; Phase 2 may change it at the peer request. Adaptive Phase 2/3 and startup-only Gen2 fallback require hardware qualification. Default 4 was used by the earlier fixed-preset board image. Rebuild and qualify the selected channel.} $preset
}
proc update_PARAM_VALUE.ENABLE_GEN3 {PARAM_VALUE.ENABLE_GEN3} {}
proc validate_PARAM_VALUE.ENABLE_GEN3 {PARAM_VALUE.ENABLE_GEN3} {
 return true
}
proc update_MODELPARAM_VALUE.ENABLE_GEN3 {MODELPARAM_VALUE.ENABLE_GEN3 PARAM_VALUE.ENABLE_GEN3} {
 set_property value [expr {[get_property value ${PARAM_VALUE.ENABLE_GEN3}] ? 1 : 0}] ${MODELPARAM_VALUE.ENABLE_GEN3}
}

proc update_PARAM_VALUE.GEN3_TX_PRESET {PARAM_VALUE.GEN3_TX_PRESET PARAM_VALUE.ENABLE_GEN3} {
 set_property enabled [get_property value ${PARAM_VALUE.ENABLE_GEN3}] ${PARAM_VALUE.GEN3_TX_PRESET}
}
proc validate_PARAM_VALUE.GEN3_TX_PRESET {PARAM_VALUE.GEN3_TX_PRESET} {
 set value [get_property value ${PARAM_VALUE.GEN3_TX_PRESET}]
 if {[string is integer -strict $value] && $value >= 0 && $value <= 10} {return true}
 return false
}
proc update_MODELPARAM_VALUE.GEN3_TX_PRESET {MODELPARAM_VALUE.GEN3_TX_PRESET PARAM_VALUE.GEN3_TX_PRESET} {
 set_property value [get_property value ${PARAM_VALUE.GEN3_TX_PRESET}] ${MODELPARAM_VALUE.GEN3_TX_PRESET}
}
