# SPDX-License-Identifier: Apache-2.0
"""Independent framing and native-link oracles for the buffered RX parser."""
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('checker', [
    'check_stream_rx.py', 'check_native_rx.py', 'check_native_link.py',
])
def test_buffered_receive(checker):
    result = subprocess.run(
        [sys.executable, str(ROOT / 'experiments/gen3' / checker)],
        cwd=ROOT, capture_output=True, text=True, timeout=180,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'PASS' in result.stdout
