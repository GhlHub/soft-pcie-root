# SPDX-License-Identifier: Apache-2.0
"""Scheduled peer blocks; never reads DUT state or uses its training transmitter.

Exercises the native training decoder plus Phase 1 controller, not a full
endpoint, analog channel, or complete LTSSM/equalization implementation.
"""
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'experiments/gen3'


class TrainingPeer:
    def __init__(self, skip, gap, preset):
        self.rows = []
        self.state = 0x1dbfbc
        self.control = 4 | (skip << 4)
        self.gap = gap
        self.preset = preset
        self.aligned = False
        self.ts_count = 0
        self.valid_ts_count = 0

    def idle(self, count=1, extra=0):
        for _ in range(count):
            self.rows.append((0, 0, 0, self.control | extra, self.preset))

    def block(self, plain, scramble=False, reset_seed=False):
        encoded = []
        for i, byte in enumerate(plain):
            mask = 0
            for bit in range(8):
                feedback = (self.state >> 22) & 1
                mask |= feedback << bit
                self.state = ((self.state << 1) & 0x7fffff) ^ (0x210125 if feedback else 0)
            encoded.append(byte ^ mask if scramble and i != 0 else byte)
        for offset in range(0, 16, 4):
            word = int.from_bytes(encoded[offset:offset + 4], 'little')
            self.rows.append((0, word, 5 | (2 if offset == 0 else 0), self.control, self.preset))
            self.idle(self.gap)
        if reset_seed:
            self.state = 0x1dbfbc
            self.aligned = True
        elif plain[0] == 0x66:
            self.aligned = False
        self.idle(2)  # drain decoder event into controller

    def eieos(self):
        self.block(bytes([0, 255]) * 8, reset_seed=True)

    def ts(self, *, kind=0x1e, lane=0, ec=1, fs=40, corrupt_parity=False):
        # Fields are built explicitly; parity covers symbols 6..9.
        fields = [ec, fs, 12, 0]
        fields[0] |= (sum(x.bit_count() for x in fields) & 1) << 5
        if corrupt_parity:
            fields[0] ^= 0x20
        self.block(bytes([kind, 0, lane, 0x20, 0x0e, 0, *fields,
                          0x4a, 0x4a, 0x4a, 0x4a, 0x4a, 0x4a]), scramble=True)
        self.ts_count += 1
        self.valid_ts_count += int(self.aligned and kind == 0x1e and lane == 0 and not corrupt_parity)
        self.rows.append((3, self.ts_count, self.valid_ts_count, 0, 0))

    def check(self, flags, reason=0, routes=0, errors=0):
        self.rows.append((1, flags, reason, routes, errors))


SCENARIOS = ['pair', 'ts2-break', 'changed-fields', 'bad-parity', 'wrong-lane',
             'wrong-ec', 'missing-ack', 'phy-loss', 'cancel-reenter', 'eios-reacquire']


@pytest.mark.parametrize('scenario', SCENARIOS)
@pytest.mark.parametrize('skip', [0, 1], ids=['phase2-handoff', 'skip23'])
@pytest.mark.parametrize('gap', [0, 2], ids=['continuous', 'gapped'])
@pytest.mark.parametrize('preset', [0, 4, 10])
def test_independent_training_peer(tmp_path, scenario, skip, gap, preset):
    peer = TrainingPeer(skip, gap, preset)
    peer.idle(extra=1)  # enter attempt, independent of DUT state
    if scenario != 'missing-ack':
        peer.idle(extra=8)
        peer.idle(4)
        peer.rows.append((2, preset, 0, 0, 0))
    peer.eieos()
    peer.ts()
    peer.check(1)  # one TS must never complete Phase 1
    if scenario == 'ts2-break':
        peer.ts(kind=0x2d)
        peer.ts()
        peer.check(1)
        peer.ts()
    elif scenario == 'changed-fields':
        peer.ts(fs=44)
        peer.check(1)
        peer.ts(fs=44)
    elif scenario in ('bad-parity', 'wrong-lane', 'wrong-ec'):
        options = {'bad-parity': {'corrupt_parity': True},
                   'wrong-lane': {'lane': 1}, 'wrong-ec': {'ec': 0}}[scenario]
        peer.ts(**options)
        peer.ts()
        peer.check(1)
        peer.ts()
    elif scenario == 'phy-loss':
        peer.control &= ~4
        peer.idle(3)
        peer.check(10, reason=5, routes=0x10000)
        # A new attempt requires another actual preset acknowledgement.
        peer.control |= 4
        peer.idle(extra=1)
        peer.eieos()
        peer.ts()
        peer.ts()
        peer.check(1, routes=0x10000)
        peer.idle(extra=8)
        peer.idle(4)
        peer.ts()
        peer.ts()
    elif scenario == 'cancel-reenter':
        peer.idle(extra=2)
        peer.check(0)
        peer.idle(extra=1)
        peer.idle(extra=8)
        peer.idle(4)
        peer.eieos()
        peer.ts()
        peer.check(1)
        peer.ts()
    elif scenario == 'eios-reacquire':
        peer.block(bytes([0x66]) * 16)
        peer.ts()
        peer.check(1)
        peer.eieos()
        peer.ts()
        peer.check(1)
        peer.ts()
    else:
        peer.ts()
    if scenario == 'missing-ack':
        peer.idle(200)
        peer.check(10, reason=2, routes=0x10000)
    else:
        peer.idle(4)
        peer.check(22 if skip else 4, routes=(1 if skip else 0x100) |
                   (0x10000 if scenario == 'phy-loss' else 0))
        peer.idle(200)
        peer.check(22 if skip else 4, routes=(1 if skip else 0x100) |
                   (0x10000 if scenario == 'phy-loss' else 0))
    vectors = tmp_path / 'peer.txt'
    vectors.write_text(''.join(f'{op} {a:x} {b:x} {c:x} {d:x}\n'
                               for op, a, b, c, d in peer.rows))
    executable = tmp_path / 'peer.vvp'
    result = subprocess.run(['iverilog', '-g2012', '-s', 'test_gen3_peer', '-o', str(executable),
                             *[str(SRC / f'{name}.sv') for name in
                               ('gen3_training_rx', 'gen3_eq_phase1', 'test_gen3_peer')]],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    result = subprocess.run(['vvp', str(executable), f'+VECTORS={vectors}'],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'PASS: independent Gen3 peer' in result.stdout


@pytest.mark.parametrize('name,filename,pattern,replacement,scenario', [
    ('single-ts', 'gen3_eq_phase1.sv',
     r' && seen_ts &&\s*rx_symbols6_9 == previous_symbols6_9', '', 'pair'),
    ('lane-check', 'gen3_training_rx.sv', r'assembled\[23:8\] == 0 &&',
     "1'b1 &&", 'wrong-lane'),
    ('parity-check', 'gen3_training_rx.sv', r'!\(\^assembled\[79:48\]\)',
     "1'b1", 'bad-parity'),
])
def test_peer_detects_broken_qualification(tmp_path, monkeypatch, name, filename,
                                           pattern, replacement, scenario):
    """Mutate isolated temporary copies; prove checks fail for specific defects."""
    import re
    import sys

    original = SRC
    for source in ('gen3_eq_phase1.sv', 'gen3_training_rx.sv', 'test_gen3_peer.sv'):
        text = (original / source).read_text()
        if source == filename:
            text, count = re.subn(pattern, replacement, text)
            assert count == 1, name
        (tmp_path / source).write_text(text)
    monkeypatch.setattr(sys.modules[__name__], 'SRC', tmp_path)
    with pytest.raises(AssertionError, match='Peer result|Peer decoder events'):
        test_independent_training_peer(tmp_path, scenario, 1, 0, 4)
