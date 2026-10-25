#!/usr/bin/env python3
"""Simulate credit-limited SSD read DMA; does not access hardware or change RTL."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    sources = sorted(p for p in (ROOT / 'ip/soft_pcie_root/rtl/pcie_soft').glob('*.sv')
                     if p.name not in ('pcie_soft_gth.sv', 'pcie_soft_root_port.sv'))
    sources += [ROOT / 'ip/soft_pcie_root/rtl/host/pcie_ddr_bridge.sv', ROOT / 'tests/host/tb_host_link.sv']
    results = []
    for refresh, delay in [(1024, 0), (512, 0), (256, 0), (128, 0), (1024, 128)]:
        name = f'fc{refresh}_b{delay}'
        exe = args.output / (name + '.vvp')
        cmd = ['iverilog', '-g2012', '-s', 'tb_host_link',
               f'-Ptb_host_link.PROFILE_FC_CYCLES={refresh}',
               f'-Ptb_host_link.PROFILE_B_DELAY={delay}', '-o', str(exe)]
        subprocess.run(cmd + [str(p) for p in sources], check=True)
        run = subprocess.run(['vvp', str(exe), '+PROFILE'], capture_output=True,
                             text=True, timeout=60)
        (args.output / (name + '.log')).write_text(run.stdout + run.stderr)
        if run.returncode:
            raise RuntimeError(run.stdout + run.stderr)
        line = next(line for line in run.stdout.splitlines() if line.startswith('PROFILE '))
        result = {k: float(v) if '.' in v else int(v)
                  for k, v in re.findall(r'(\w+)=([\d.]+)', line)}
        assert result['bytes'] == 65536
        results.append(result)
        print(line, flush=True)
    evidence = {'kind': 'simulation, not board measurements', 'results': results,
                'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in sources + [Path(__file__)]}}
    (args.output / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')

if __name__ == '__main__':
    main()
