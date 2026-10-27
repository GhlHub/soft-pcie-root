#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Training-only MAC integration test; external PHY is a behavioral handshake model."""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'experiments/gen3'
OUT=Path(tempfile.mkdtemp(prefix='gen3_recovery_bringup_',dir=ROOT/'build'))
files=[SRC/f'{n}.sv' for n in ('gen3_eq_bringup','gen3_legacy_training',
    'gen3_startup_ltssm','gen3_training_tx','gen3_training_rx','gen3_recovery_tx','gen3_native_rx','gen3_data_rx','gen3_stream_rx','gen3_stream_buffered_rx','gen3_packet_gate','gen3_eq_phase1')]
files.extend(SRC/(n+'.sv') for n in ('gen3_dllp_source','gen3_link_layer','gen3_link_profile','gen3_replay_tx','gen3_tx_window','gen3_tlp_source','gen3_stp'))
files.extend(ROOT/('ip/soft_pcie_root/rtl/pcie_soft/'+n+'.sv') for n in ('pcie_soft_requester','pcie_soft_replay','pcie_soft_ack_capture'))
files.append(ROOT/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_flow_control.sv')
files.append(ROOT/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_scrambler.sv')
subprocess.run(['verilator','--lint-only','--Wall','--top-module','gen3_eq_bringup',*map(str,files)],check=True)
subprocess.run(['verilator','--lint-only','--Wall','--top-module','gen3_eq_bringup',
    '-GRECOVERY_ENABLE=1','-GDATALINK_ENABLE=1','-GCONFIG_PROBE=1',*map(str,files)],check=True)
for fault,dl,missing in ((0,0,0),(12,0,0),(13,0,0),(14,0,0),(0,1,0),(0,1,1)):
    binary=OUT/f'test_{fault}_{dl}_{missing}'
    subprocess.run(['iverilog','-g2012','-DGEN3_RX_DIAGNOSTICS','-s','test_recovery_bringup',
        f'-Ptest_recovery_bringup.FAULT={fault}',f'-Ptest_recovery_bringup.DATALINK={dl}',f'-Ptest_recovery_bringup.MISSING_NP={missing}','-o',str(binary),
        str(SRC/'test_recovery_bringup.sv'),*map(str,files)],check=True)
    subprocess.run(['vvp',str(binary)],check=True)
print(f'Integrated equalization results: {OUT}')
