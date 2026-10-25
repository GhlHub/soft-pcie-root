#!/usr/bin/env python3
"""Compile/elaborate and test the command bridge against AMD's real XPM library.
No behavioral substitute is used. All simulator artifacts stay in output.
"""
import argparse, os, re, subprocess, tempfile, shutil
from pathlib import Path
R = Path(__file__).resolve().parents[1]
def run(output, elaborate_only=False):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    vivado = Path(os.environ['VIVADO_BIN']) if 'VIVADO_BIN' in os.environ else Path(shutil.which('vivado') or '/missing-vivado/bin/vivado').resolve().parent
    def tool(name, args):
        result = subprocess.run([str(vivado/name), *map(str,args)], cwd=output,
                                capture_output=True, text=True, timeout=180)
        log = result.stdout + result.stderr
        (output/(name+'-output.txt')).write_text(log)
        if result.returncode or re.search(r'(?m)^(?:ERROR:|Fatal:)', log):
            raise RuntimeError(log)
        return log
    tool('xvlog', ['--sv', R/'ip/soft_pcie_root/rtl/host/pcie_cmd_fifo.sv',
                  R/'ip/soft_pcie_root/rtl/host/pcie_cmd_cdc.sv', R/'tests/host/tb_cmd_cdc.sv',
                  vivado.parent/'data/verilog/src/glbl.v'])
    tool('xelab', ['-L','xpm','-L','unisims_ver','work.tb_cmd_cdc','work.glbl',
                  '-s','cmd_cdc_xpm','--debug','typical'])
    if not elaborate_only:
        log = tool('xsim', ['cmd_cdc_xpm','-runall'])
        checked = re.sub(r'(?m)^Warning: SIM_ASSERT_CHK \(1\) specifies simulation message reporting, messages related to potential misuse will be reported\.\n', '', log)
        if 'PASS CMD CDC:' not in log or re.search(r'(?im)^(warning:|error:|fatal:)',checked):
            raise RuntimeError(log)
    print('CMD_XPM_ELABORATION_PASS' if elaborate_only else 'CMD_XPM_SIMULATION_PASS')
if __name__ == '__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--output',type=Path)
    p.add_argument('--elaborate-only',action='store_true')
    a=p.parse_args()
    if a.output: run(a.output,a.elaborate_only)
    else:
        with tempfile.TemporaryDirectory(prefix='zcu104-cmd-xpm-') as d:
            run(d,a.elaborate_only)
