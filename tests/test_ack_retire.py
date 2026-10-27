from pathlib import Path
import subprocess
R=Path(__file__).resolve().parents[1]
def test_normal_ack_retirement(tmp_path):
 for period in (17,53):
  exe=tmp_path/f'ack-{period}'
  subprocess.run(['iverilog','-g2012','-s','tb_ack_retire',f'-Ptb_ack_retire.ACK_PERIOD={period}','-o',str(exe),str(R/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_replay.sv'),str(R/'tests/pcie_soft/tb_ack_retire.sv')],check=True)
  r=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=30)
  assert r.returncode==0,r.stdout+r.stderr
  assert 'PASS ACK RETIRE:' in r.stdout

def test_ack_retirement_simultaneous_edges(tmp_path):
 exe=tmp_path/'ack-edges'
 subprocess.run(['iverilog','-g2012','-s','tb_ack_retire_edges','-o',str(exe),str(R/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_replay.sv'),str(R/'tests/pcie_soft/tb_ack_retire_edges.sv')],check=True)
 r=subprocess.run(['vvp',str(exe)],capture_output=True,text=True,timeout=30)
 assert r.returncode==0,r.stdout+r.stderr
 assert 'PASS ACK EDGES:' in r.stdout
