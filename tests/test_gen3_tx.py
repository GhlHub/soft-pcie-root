# SPDX-License-Identifier: Apache-2.0
"""Wire-level Recovery TX oracle, including cadence-boundary stop requests."""
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('phase', [None, -1, 0, 1, 63, 64])
def test_recovery_wire_and_stop(phase):
    command = [sys.executable, str(ROOT / 'experiments/gen3/check_recovery_tx.py')]
    if phase is not None:
        command += ['--initfc1', '--stop-phase', str(phase)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'PASS: independent Recovery TX oracle' in result.stdout
    if phase is not None:
        assert 'ordered InitFC1 packets, CRC, spacing, atomic stop phase' in result.stdout
