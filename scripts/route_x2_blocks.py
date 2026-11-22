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
LEGACY_LINK = 'pcie_soft_link'
GEN3_TX = 'gen3_x2_recovery_tx'
GEN3_RX = 'gen3_x2_receive'
GEN3_PORT = 'gen3_x2_post_port'
LEGACY_SOURCES = [GEN3 + 'gen3_legacy_x2_phy.sv'] + [CORE + name + '.sv' for name in (
    'pcie_soft_link', 'pcie_soft_ltssm', 'pcie_soft_packet_rx', 'pcie_soft_packet_tx',
    'pcie_soft_scrambler', 'pcie_soft_training', 'pcie_lane_stripe', 'pcie_legacy_x2_rx',
    'pcie_legacy_x2_packet_rx')]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path)
    p.add_argument('--part', default='xczu15eg-ffvb1156-2-e')
    p.add_argument('--vivado', default='/tools/Xilinx/2026.1/Vivado/bin/vivado')
    p.add_argument('--targets', nargs='+', choices=[*TARGETS, LEGACY_LINK, GEN3_TX, GEN3_RX, GEN3_PORT],
                   default=TARGETS)
    p.add_argument('--legacy-gen2', action='store_true', help='route pcie_soft_link at 250 MHz')
    a = p.parse_args()
    if a.legacy_gen2 and LEGACY_LINK not in a.targets:
        p.error('--legacy-gen2 requires pcie_soft_link')
    output = a.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    snapshot = output/'source'
    hashes = {}
    sources = list(SOURCES)
    if LEGACY_LINK in a.targets:
        sources.extend(LEGACY_SOURCES)
    if GEN3_TX in a.targets or GEN3_PORT in a.targets:
        sources.extend([GEN3 + GEN3_TX + '.sv', GEN3 + 'gen3_recovery_tx.sv',
                        CORE + 'pcie_lane_stripe.sv'])
    if GEN3_RX in a.targets or GEN3_PORT in a.targets:
        sources.extend([GEN3 + GEN3_RX + '.sv', GEN3 + 'gen3_native_rx.sv',
                        CORE + 'pcie_lane_stripe.sv'])
    if GEN3_PORT in a.targets:
        sources.extend([GEN3 + GEN3_PORT + '.sv', GEN3 + 'gen3_x2_post_eq.sv'])
    for relative in dict.fromkeys(sources):
        data = (ROOT/relative).read_bytes()
        dest = snapshot/relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        hashes[relative] = hashlib.sha256(data).hexdigest()
    manifest = {'scope': 'separate routed OOC blocks; not full root/PHY/board',
                'part': a.part, 'targets': a.targets, 'legacy_gen2': a.legacy_gen2,
                'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                'sha256': hashes}
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    results = {}
    for target in a.targets:
        print(f'START {target}', flush=True)
        with (output/f'{target}.log').open('w') as log:
            result = subprocess.run([a.vivado, '-mode', 'batch', '-notrace', '-log', str(output/f'{target}.vivado.log'),
                '-journal', str(output/f'{target}.jou'), '-source', str(snapshot/'scripts/route_x2_blocks.tcl'),
                '-tclargs', str(snapshot), str(output/target), a.part, target, str(int(a.legacy_gen2))],
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
