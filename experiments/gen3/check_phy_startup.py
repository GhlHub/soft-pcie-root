#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Test locally generated reset RTL; no generated AMD source is distributed."""
from pathlib import Path
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[2]
base=Path(sys.argv[1])/'source'
out=Path(tempfile.mkdtemp(prefix='gen3_phy_startup_',dir=root/'build'))
files=[base/f'gen3_reference_phy_{name}.v' for name in ['gt_phy_rst','sync','sync_cell']]
for mode in (0,1):
    binary=out/f'test_{mode}'
    subprocess.run(['iverilog','-g2012','-s','test_phy_startup',
        f'-Ptest_phy_startup.STARTUP_REFERENCE={mode}','-o',str(binary),
        str(root/'experiments/gen3/test_phy_startup.sv'),*map(str,files)],check=True)
    subprocess.run(['vvp',str(binary)],check=True)
print(f'Reset/clock dependency test results: {out}')
