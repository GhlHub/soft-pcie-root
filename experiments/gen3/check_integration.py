#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise the integrated experimental transmit path with a behavioral sink."""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'experiments/gen3'
OUT=Path(tempfile.mkdtemp(prefix='gen3_integration_',dir=ROOT/'build'))
names=['gen3_tx_path','gen3_tx_completion','gen3_phy_control','gen3_phy_rate',
       'gen3_clock_watch','gen3_tx_schedule','gen3_tx_cadence','gen3_scrambler']
sources=[str(SRC/(name+'.sv')) for name in names]
subprocess.run(['iverilog','-g2012','-s','test_tx_path','-o',str(OUT/'test'),
                *sources,str(SRC/'test_tx_path.sv')],check=True)
subprocess.run(['vvp',str(OUT/'test')],check=True)
subprocess.run(['verilator','--lint-only','--Wall','--top-module','gen3_tx_path',*sources],check=True)
print(f'Integrated transport results: {OUT}')
