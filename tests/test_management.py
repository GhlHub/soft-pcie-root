from pathlib import Path
import subprocess
R=Path(__file__).resolve().parents[1]
def test_axi_mailbox(tmp_path):
 exe=tmp_path/'test.vvp'
 subprocess.run(['iverilog','-g2012','-s','tb_csr','-o',exe,R/'ip/soft_pcie_root/rtl/management/pcie_root_csr.sv',R/'tests/pcie_soft/tb_csr.sv'],check=True)
 r=subprocess.run(['vvp',exe],check=True,text=True,capture_output=True,timeout=20)
 assert 'PASS CSR:' in r.stdout

def test_host_tool_build_and_usage(tmp_path):
 exe=tmp_path/'pcie-rootctl'
 subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-o',exe,R/'software/tools/pcie-rootctl.c'],check=True)
 r=subprocess.run([exe],capture_output=True,text=True)
 assert r.returncode==2 and 'Usage:' in r.stderr


def test_csr_early_fault_drain(tmp_path):
 for cause in (1, 2):
  exe=tmp_path/f'early-{cause}'
  subprocess.run(['iverilog','-g2012','-s','tb_csr',f'-Ptb_csr.EARLY_FAULT={cause}',
   '-o',exe,R/'ip/soft_pcie_root/rtl/management/pcie_root_csr.sv',R/'tests/pcie_soft/tb_csr.sv'],check=True)
  result=subprocess.run(['vvp',exe],capture_output=True,text=True,timeout=20)
  assert result.returncode == 0, result.stdout+result.stderr
  assert 'early fault and late accepted-owner drain' in result.stdout
