# SPDX-License-Identifier: Apache-2.0
"""Exercise the actual Vivado GUI callbacks without requiring a GUI session."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def test_preset_gui_validation_and_propagation(tmp_path):
    script = tmp_path / 'gui.tcl'
    script.write_text(r'''
array set props {}
proc set_property {key value object} {global props; set props($object,$key) $value}
proc get_property {key object} {global props; return $props($object,$key)}
source [lindex $argv 0]
foreach value {0 4 10} {
 set_property value $value preset
 if {[validate_PARAM_VALUE.GEN3_TX_PRESET preset] ne "true"} {error "Valid preset rejected"}
 update_MODELPARAM_VALUE.GEN3_TX_PRESET model preset
 if {[get_property value model] != $value} {error "Model preset did not propagate"}
}
foreach value {-1 11 garbage 1.5} {
 set_property value $value preset
 if {[validate_PARAM_VALUE.GEN3_TX_PRESET preset] ne "false"} {error "Invalid preset accepted"}
}
foreach enabled {false true} {
 set_property value $enabled gen3
 update_PARAM_VALUE.GEN3_TX_PRESET preset gen3
 if {[get_property enabled preset] ne $enabled} {error "Gen3 enable dependency failed"}
}
puts PASS
''')
    result = subprocess.run(['tclsh', str(script), str(ROOT/'ip/soft_pcie_root/xgui/soft_pcie_root.tcl')],
                            capture_output=True, text=True, check=True)
    assert result.stdout.strip() == 'PASS'
