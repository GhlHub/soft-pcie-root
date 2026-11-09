#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Snapshot and route available x2 blocks separately, without changing RTL."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
GEN3 = 'experiments/gen3/'
HOST = 'ip/soft_pcie_root/rtl/host/'
CORE = 'ip/soft_pcie_root/rtl/pcie_soft/'
SOURCES = ([GEN3+n+'.sv' for n in (
    'gen3_data_rx_x2', 'gen3_link_layer_x2', 'gen3_link_profile', 'gen3_dllp_source_x2',
    'gen3_tx_window_x2', 'gen3_tlp_source_x2', 'gen3_stp', 'gen3_multilane_startup',
    'gen3_multilane_eq', 'gen3_training_rx', 'gen3_training_tx', 'gen3_eq_phase1', 'gen3_eq_adapt')]
    + [HOST+n+'.sv' for n in ('pcie_x2_host_path', 'pcie_ddr_bridge_x2', 'pcie_packet_width', 'pcie_cdc_packet')]
    + [CORE+n+'.sv' for n in ('pcie_soft_flow_control', 'pcie_soft_requester', 'pcie_soft_replay',
                             'pcie_soft_ack_capture', 'pcie_lane_deskew')]
    + ['scripts/route_x2_blocks.tcl', 'scripts/route_x2_blocks.py'])
TARGETS = ['gen3_data_rx_x2', 'gen3_link_layer_x2', 'pcie_x2_host_path',
           'gen3_multilane_startup', 'gen3_multilane_eq', 'pcie_lane_deskew']


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path)
    p.add_argument('--part', default='xczu15eg-ffvb1156-2-e')
    p.add_argument('--vivado', default='/tools/Xilinx/2026.1/Vivado/bin/vivado')
    p.add_argument('--targets', nargs='+', choices=TARGETS, default=TARGETS)
    a = p.parse_args()
    output = a.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    snapshot = output/'source'
    hashes = {}
    for relative in SOURCES:
        data = (ROOT/relative).read_bytes()
        dest = snapshot/relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        hashes[relative] = hashlib.sha256(data).hexdigest()
    manifest = {'scope': 'separate routed OOC blocks; not full root/PHY/board',
                'part': a.part, 'targets': a.targets,
                'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'sha256': hashes}
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    results = {}
    for target in a.targets:
        print(f'START {target}', flush=True)
        with (output/f'{target}.log').open('w') as log:
            result = subprocess.run([a.vivado, '-mode', 'batch', '-notrace', '-log', str(output/f'{target}.vivado.log'),
                '-journal', str(output/f'{target}.jou'), '-source', str(snapshot/'scripts/route_x2_blocks.tcl'),
                '-tclargs', str(snapshot), str(output/target), a.part, target],
                cwd=output, stdout=log, stderr=subprocess.STDOUT)
        success = result.returncode == 0 and (output/target/'complete.txt').exists()
        results[target] = {'exit_code': result.returncode, 'routed': success}
        (output/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(f'{"DONE" if success else "FAILED"} {target}', flush=True)
    for relative, expected in hashes.items():
        if hashlib.sha256((snapshot/relative).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f'Snapshot changed: {relative}')
    return 0 if all(r['routed'] for r in results.values()) else 1


if __name__ == '__main__':
    sys.exit(main())
