#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise preset/policy/delay/fault combinations; no analog PHY model implied."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'experiments/gen3'
OUT = Path(tempfile.mkdtemp(prefix='gen3_equalization_', dir=ROOT / 'build'))
files = [SRC / name for name in ('gen3_eq_phase1.sv', 'test_eq_phase1.sv',
                                 'test_eq_matrix.sv', 'check_equalization.py')]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
subprocess.run(['verilator', '--lint-only', '--Wall', str(files[0])], check=True)
runs = [('test_eq_phase1', None)] + [('test_eq_matrix', n) for n in (0, 2, 125)]
for top, settle in runs:
    binary = OUT / f'{top}_{settle}'
    command = ['iverilog', '-g2012', '-s', top, '-o', str(binary)]
    if settle is not None:
        command += [f'-P{top}.SETTLE={settle}']
    subprocess.run(command + [str(files[0]), str(SRC / f'{top}.sv')], check=True)
    result = subprocess.run(['vvp', str(binary)], text=True, capture_output=True, check=True)
    print(result.stdout, end='')
    binary.with_suffix('.log').write_text(result.stdout + result.stderr)
assert hashes == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(OUT / 'results.json').write_text(json.dumps({
    'result': 'pass', 'matrix_cases': 2376, 'settle_cycles': [0, 2, 125],
    'preset_labels': list(range(11)), 'ack_delay_cycles': [0, 1, 7, 17],
    'policies': ['phase2_handoff', 'skip_phase23'], 'scenarios_per_combination': 9,
    'source_sha256': hashes, 'scope': 'control-plane simulation only; no analog preset ranking'
}, indent=2) + '\n')
print(f'Equalization results: {OUT}')
