from pathlib import Path
import subprocess
R=Path(__file__).resolve().parents[1]
def test_ddr_bridge(tmp_path):
 exe=tmp_path/'ddr.vvp'
 subprocess.run(['iverilog','-g2012','-s','tb_ddr_bridge','-o',exe,R/'ip/soft_pcie_root/rtl/host/pcie_ddr_bridge.sv',R/'tests/host/tb_ddr_bridge.sv'],check=True)
 r=subprocess.run(['vvp',exe],capture_output=True,text=True,timeout=30)
 assert r.returncode==0,r.stdout+r.stderr
 assert 'PASS DDR:' in r.stdout

def test_host_axi(tmp_path):
 exe=tmp_path/'host.vvp'
 subprocess.run(['iverilog','-g2012','-s','tb_host_axi','-o',exe,R/'ip/soft_pcie_root/rtl/host/pcie_host_axi.sv',R/'tests/host/tb_host_axi.sv'],check=True)
 r=subprocess.run(['vvp',exe],capture_output=True,text=True,timeout=30)
 assert r.returncode==0,r.stdout+r.stderr
 assert 'PASS HOST:' in r.stdout

def test_cmd_mux(tmp_path):
 exe=tmp_path/'mux.vvp'
 subprocess.run(['iverilog','-g2012','-s','tb_cmd_mux','-o',exe,R/'ip/soft_pcie_root/rtl/host/pcie_cmd_mux.sv',R/'tests/host/tb_cmd_mux.sv'],check=True)
 r=subprocess.run(['vvp',exe],capture_output=True,text=True,timeout=30)
 assert r.returncode==0,r.stdout+r.stderr
 assert 'PASS MUX:' in r.stdout

def test_host_link(tmp_path):
 exe=tmp_path/'host-link.vvp'
 sources=sorted(p for p in (R/'ip/soft_pcie_root/rtl/pcie_soft').glob('*.sv') if p.name not in ('pcie_soft_gth.sv','pcie_soft_root_port.sv'))
 subprocess.run(['iverilog','-g2012','-s','tb_host_link','-o',exe,*sources,R/'ip/soft_pcie_root/rtl/host/pcie_ddr_bridge.sv',R/'tests/host/tb_host_link.sv'],check=True)
 r=subprocess.run(['vvp',exe],capture_output=True,text=True,timeout=30)
 assert r.returncode==0,r.stdout+r.stderr
 assert 'PASS HOST LINK:' in r.stdout

def test_cdc_packet(tmp_path):
 exe=tmp_path/'cdc.vvp'
 subprocess.run(['iverilog','-g2012','-s','tb_cdc_packet','-o',exe,R/'ip/soft_pcie_root/rtl/host/pcie_cdc_packet.sv',R/'tests/host/tb_cdc_packet.sv'],check=True)
 r=subprocess.run(['vvp',exe],capture_output=True,text=True,timeout=30)
 assert r.returncode==0,r.stdout+r.stderr
 assert 'PASS CDC:' in r.stdout

def test_cmd_cdc(tmp_path):
 subprocess.run(['python3',R/'scripts/test_cmd_xpm.py','--output',tmp_path],check=True,timeout=240)

def test_ddr_pipeline(tmp_path):
 exe=tmp_path/'pipeline.vvp'
 subprocess.run(['iverilog','-g2012','-s','tb_ddr_pipeline','-o',exe,R/'ip/soft_pcie_root/rtl/host/pcie_ddr_bridge.sv',R/'tests/host/tb_ddr_pipeline.sv'],check=True)
 r=subprocess.run(['vvp',exe],capture_output=True,text=True,timeout=30)
 assert r.returncode==0,r.stdout+r.stderr
 assert 'PASS PIPELINE:' in r.stdout

def test_completion_tx_profile(tmp_path):
 for ack_every in (1,4):
  exe=tmp_path/f'completion-tx-{ack_every}.vvp'
  subprocess.run(['iverilog','-g2012','-s','tb_completion_tx_profile',f'-Ptb_completion_tx_profile.ACK_EVERY={ack_every}','-o',exe,R/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_replay.sv',R/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_packet_tx.sv',R/'tests/host/tb_completion_tx_profile.sv'],check=True)
  run=subprocess.run(['vvp',exe],capture_output=True,text=True,timeout=30)
  assert run.returncode==0,run.stdout+run.stderr
  assert 'PASS COMPLETION TX:' in run.stdout
