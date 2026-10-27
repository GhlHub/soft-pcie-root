from pathlib import Path
import subprocess
R=Path(__file__).resolve().parents[1]
def test_link_profile(tmp_path):
 exe=tmp_path/'profile'
 subprocess.run(['iverilog','-g2012','-s','test_link_profile','-o',str(exe),str(R/'experiments/gen3/gen3_link_profile.sv'),str(R/'experiments/gen3/test_link_profile.sv')],check=True)
 run=subprocess.run(['vvp',str(exe)],check=True,capture_output=True,text=True,timeout=30)
 assert 'PASS LINK PROFILE:' in run.stdout
