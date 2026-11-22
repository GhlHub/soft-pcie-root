# SPDX-License-Identifier: Apache-2.0
"""Run the independent symbol-level endpoint against the native-PHY fallback.
Reuse the full existing packet/CRC/replay scenario, replacing only its PHY adapter.
"""
from pathlib import Path
import re
import subprocess
import pytest
ROOT=Path(__file__).resolve().parents[1]
@pytest.mark.parametrize('gen2,initial_rate,fault',[(0,2,0),(1,2,0),(1,0,0),(1,2,1),(1,2,2)])
def test_fallback_packet_path(tmp_path,gen2,initial_rate,fault):
    source=(ROOT/'tests/pcie_soft/tb_root_link.sv').read_text()
    source=source.replace('pcie_soft_link #(', 'gen3_gen2_fallback #(').replace('.GEN2_ENABLE       (GEN2_TEST),', '.IDLE_CYCLES(8),')
    source=re.sub(r'\s*\.LINK_WIDTH\s*\(LINK_WIDTH\),', '', source)
    source=source.replace('dut.', 'dut.link.')
    remove=['phy_gen2_i','phy_rate_ready_i','target_gen2_o','speed_idle_o','fallback_o','enable_i','detect_done_i','receiver_present_i','phy_rx_error_i']
    for name in remove: source=re.sub(r'\s*\.'+name+r'\s*\([^\n]*\),','',source)
    rename={'rst_n':'reset_i','electrical_idle_o':'idle_o','phy_rx_data_i':'rx_data_i','phy_rx_ctrl_i':'rx_k_i','phy_rx_valid_i':'rx_valid_i','phy_tx_data_o':'tx_data_o','phy_tx_ctrl_o':'tx_k_o'}
    for a,b in rename.items():source=source.replace('.'+a+' ','.'+b+' ')
    source=source.replace('.reset_i             (rst),', '.reset_i(!rst), .start_i(rst), .initial_rate_i(2\'d2),\n        .phystatus_i(phystatus), .rx_status_i(3\'d3), .powerdown_o(powerdown),')
    source=source.replace('    wire targetgen2, speedidle, fallback;', '    reg phystatus=0; wire [1:0] powerdown;\n    wire targetgen2, speedidle, fallback;\n    assign speedidle=dut.speed_idle; assign targetgen2=dut.target_gen2;')
    source=source.replace('        wait (detect);','        wait(dut.rate_o==0); cycles(4); phystatus=1; cycles(1); phystatus=0;\n        wait (detect);')
    source=source.replace('        detectdone = 1;','        phystatus=1;').replace('        detectdone   = 0;','        phystatus=0; wait(powerdown==0); cycles(4); phystatus=1; cycles(1); phystatus=0;')
    source=source.replace('        rateready = 1;', '        rateready = 1; phystatus=1; cycles(1); phystatus=0;')
    source=source.replace(".initial_rate_i(2'd2)", f".initial_rate_i(2'd{initial_rate})")
    if initial_rate==0:
        source=source.replace('wait(dut.rate_o==0); cycles(4); phystatus=1; cycles(1); phystatus=0;', 'wait(dut.run);')
    # The existing peer changes rate twice with a real configuration read pending.
    source=source.replace('    integer before_packets,', "    reg preserve_epoch=0;\n    always @(posedge clk) if(preserve_epoch && (!active || !up))\n        $fatal(1, \"rate switch dropped accepted ownership epoch\");\n    integer before_packets,")
    source=source.replace('            partner_speed(0);', '            preserve_epoch=1; partner_speed(0);')
    source=source.replace('            partner_speed(1);', '            partner_speed(1); preserve_epoch=0;')
    if fault:
        source=source.replace('.IDLE_CYCLES(8),', '.IDLE_CYCLES(8), .SWITCH_TIMEOUT(64),')
        a=source.index('    initial begin\n        cycles(4);')
        b=source.index('    initial begin',a+20)
        source=source[:a]+'''    initial begin
            cycles(4); @(negedge clk); rst=1;
            phystatus=FAULT_VALUE;
            wait(dut.state==5); #1;
            if(up || active || !txidle || !error) $fatal(1,"unsafe failed switch");
            if(FAULT_VALUE && dut.rate_o!=2) $fatal(1,"stale PHYSTATUS changed rate");
            $display("PASS integrated missing/stale rate acknowledgement"); $finish;
        end
''' .replace('FAULT_VALUE',str(int(fault==2)))+source[b:]
    bench=tmp_path/'tb_root_link.sv';bench.write_text(source)
    files=sorted((ROOT/'ip/soft_pcie_root/rtl/pcie_soft').glob('*.sv'))
    exe=tmp_path/'sim'
    result=subprocess.run(['iverilog','-g2012','-s','tb_root_link',f'-Ptb_root_link.GEN2_TEST={gen2}',
        '-o',str(exe),str(bench),str(ROOT/'experiments/gen3/gen3_gen2_fallback.sv'),*map(str,files)],capture_output=True,text=True)
    assert result.returncode==0,result.stderr
    result=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=60)
    assert result.returncode==0,result.stdout+result.stderr
    assert 'PASS integrated' in result.stdout
