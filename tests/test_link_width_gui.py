# SPDX-License-Identifier: Apache-2.0
"""Exercise real XGUI callbacks and prevent an x2 request from becoming x1 RTL."""
from pathlib import Path
import subprocess
import pytest
ROOT=Path(__file__).resolve().parents[1]


def test_width_gui_validation_and_propagation(tmp_path):
    script=tmp_path/'gui.tcl'
    script.write_text(r'''
array set props {}
proc set_property {key value object} {global props;set props($object,$key) $value}
proc get_property {key object} {global props;return $props($object,$key)}
source [lindex $argv 0]
foreach gen3 {false true} {
 set_property value $gen3 gen3
 foreach width {1 2} {
  set_property value $width width
  set expected [expr {$width==1 || $gen3}]
  if {!![validate_PARAM_VALUE.LINK_WIDTH width gen3] != $expected} {error "Invalid width/Gen3 matrix"}
  update_MODELPARAM_VALUE.LINK_WIDTH model width
  if {[get_property value model] != $width} {error "Width did not reach HDL parameter"}
 }
}
foreach width {0 3 4 -1 garbage 1.5} {
 set_property value $width width
 if {[validate_PARAM_VALUE.LINK_WIDTH width gen3]} {error "Invalid width accepted"}
}
# Changing Gen3 must not silently narrow the user's requested two-lane design.
set_property value 2 width
set_property value false gen3
if {[validate_PARAM_VALUE.LINK_WIDTH width gen3]} {error "Unsupported legacy x2 accepted"}
if {[get_property value width] != 2} {error "Width silently changed"}
puts PASS
''')
    r=subprocess.run(['tclsh',str(script),str(ROOT/'ip/soft_pcie_root/xgui/soft_pcie_root.tcl')],
                     text=True,capture_output=True,check=True)
    assert r.stdout.strip()=='PASS'


@pytest.mark.parametrize('width,gen3',[(1,0),(1,1),(2,1),(3,1)])
def test_root_width_guard(tmp_path,width,gen3):
    # -i blackboxes missing AMD PHY/XPM primitives ONLY for this parameter-guard
    # test. This neither simulates a PHY nor qualifies the integrated host shell.
    sources=sorted((ROOT/'ip/soft_pcie_root/rtl').rglob('*.sv'))
    sources+=sorted((ROOT/'experiments/gen3').glob('gen3_*.sv'))
    output=tmp_path/'guard'
    command=['iverilog','-g2012','-i','-s','soft_pcie_root',
             f'-Psoft_pcie_root.LINK_WIDTH={width}',f'-Psoft_pcie_root.ENABLE_GEN3={gen3}',
             '-o',str(output),*map(str,sources)]
    r=subprocess.run(command,text=True,capture_output=True)
    assert r.returncode==0,r.stderr
    r=subprocess.run(['vvp',str(output)],text=True,capture_output=True,timeout=20)
    if width==1:
        assert r.returncode==0,r.stdout+r.stderr
    else:
        expected = 'root backend is not integrated' if width==2 else 'LINK_WIDTH must be 1 or 2'
        assert r.returncode!=0 and expected in r.stdout
        # Ordinary elaboration must also reject the unresolved backend; synthesis
        # must not optimize away an initial-only warning and produce x1 hardware.
        command.remove('-i')
        r=subprocess.run(command,text=True,capture_output=True)
        assert r.returncode!=0 and 'soft_pcie_x2_phy_packet_backend_not_integrated' in r.stderr
