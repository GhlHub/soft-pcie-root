# SPDX-License-Identifier: Apache-2.0
"""Isolate native-wrapper backend selection; real RTL, mocked PHY boundary only."""
from pathlib import Path
import re
import subprocess
import pytest
ROOT=Path(__file__).resolve().parents[1]
@pytest.mark.parametrize('owned',[0,1])
def test_no_backend_reset_after_l0(tmp_path,owned):
    native=(ROOT/'experiments/gen3/gen3_native_root.sv').read_text()
    ports=re.findall(r'\.(\w+)\s*\(',native.split('gen3_reference_phy phy (')[1].split('    );')[0])
    outputs={'phy_pclk':1,'eq_diag':64,'phy_coreclk':1,'phy_userclk':1,'phy_mcapclk':1,'phy_rxdata':64,
             'phy_rxdatak':2,'phy_rxdata_valid':1,'phy_rxstart_block':2,'phy_rxsync_header':2,'phy_rxvalid':1,
             'phy_phystatus':1,'phy_phystatus_rst':1,'phy_rxelecidle':1,'phy_rxstatus':3,'phy_txeq_fs':6,
             'phy_txeq_lf':6,'phy_txeq_new_coeff':18,'phy_txeq_done':1,'phy_rxeq_preset_sel':1,
             'phy_rxeq_new_txcoeff':18,'phy_rxeq_adapt_done':1,'phy_rxeq_done':1,'gt_gtpowergood':1,'phy_txp':1,'phy_txn':1}
    # Input widths are not modeled electrically; use exact widths from known PHY contract.
    inputs={'phy_txdata':64,'phy_txdatak':2,'phy_txsync_header':2,'phy_powerdown':2,'phy_rate':2,
            'phy_txmargin':3,'phy_txeq_ctrl':2,'phy_txeq_preset':4,'phy_txeq_coeff':6,
            'phy_rxeq_ctrl':2,'phy_rxeq_txpreset':4}
    stub='module gen3_reference_phy('+','.join(ports)+');\n'
    for name in ports:
        width=outputs.get(name,inputs.get(name,1)); stub+=f'{"output" if name in outputs else "input"} wire [{width-1}:0] {name};\n'
        if name in outputs:stub+=f'assign {name} = '+('phy_refclk' if name=='phy_pclk' else "'0")+';\n'
    stub+='''endmodule
module IBUFDS_GTE4 #(parameter REFCLK_HROW_CK_SEL=0)(input I,IB,CEB,output O,ODIV2);assign O=I;assign ODIV2=I;endmodule
module BUFG_GT(input I,CE,CEMASK,CLR,CLRMASK,input [2:0] DIV,output O);assign O=I;endmodule
module guard_test;
reg clk=0;always #2 clk=~clk;
reg [127:0] s=0; reg failed=0, active=0;
wire fallback, cmdready;
gen3_native_root dut(.freerun_clk_i(clk),.reset_i(1'b0),.enable_i(1'b1),.refclk_p_i(clk),.refclk_n_i(!clk),
 .rx_p_i(1'b0),.rx_n_i(1'b1),.retrain_i(1'b0),.force_gen1_i(1'b0),
 .cmd_valid_i(1'b1),.cmd_op_i(3'd7),.cmd_address_i(64'b0),.cmd_bdf_i(16'b0),.cmd_data_i(32'b0),.cmd_be_i(4'hf),
 .rsp_ready_i(1'b0),.cmd_ready_o(cmdready),.app_tx_valid_i(1'b0),.app_tx_last_i(1'b0),.app_tx_data_i(32'b0),
 .app_tx_class_i(2'b0),.app_tx_credits_i(9'b0),.app_rx_ready_i(1'b0),.fallback_o(fallback));
initial begin
 force dut.release_sync=0; force dut.rate=0;
 force dut.status=s; force dut.idle=1; force dut.startup_failed=failed; force dut.g3_dl_active_o=active;
 repeat(4) @(negedge clk);force dut.release_sync=7;
 repeat(4) @(negedge clk);
 #0.2; force dut.rate=2;
 #0.2; if(dut.phy.phy_rate != 0) $fatal(1,"combinational PHY rate change");
 @(negedge clk);
 if(dut.phy.phy_rate != 2) $fatal(1,"registered PHY rate missing");
 if(cmdready) $fatal(1,"accepted command before backend ownership");
 if(OWNED) begin s=18;active=1;repeat(2) @(negedge clk);end
 s=14; active=0; failed=1;
 repeat(8) @(negedge clk);
 if(fallback != !OWNED) $fatal(1,"backend ownership guard");
 $display("PASS: startup backend selection ownership guard");$finish;
end
endmodule
'''.replace('OWNED',str(owned))
    f=tmp_path/'guard.sv';f.write_text(stub)
    files=sorted((ROOT/'experiments/gen3').glob('gen3_*.sv'))+sorted((ROOT/'ip/soft_pcie_root/rtl/pcie_soft').glob('*.sv'))
    exe=tmp_path/'sim'
    result=subprocess.run(['iverilog','-g2012','-s','guard_test','-o',str(exe),str(f),*map(str,files)],capture_output=True,text=True)
    assert result.returncode==0,result.stderr
    result=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=15)
    assert result.returncode==0,result.stdout+result.stderr
    assert 'PASS:' in result.stdout
