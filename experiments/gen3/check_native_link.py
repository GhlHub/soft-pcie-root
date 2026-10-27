#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'experiments/gen3';CORE=ROOT/'ip/soft_pcie_root/rtl/pcie_soft'
out=Path(tempfile.mkdtemp(prefix='gen3_native_link_',dir=ROOT/'build'))
files=[SRC/(n+'.sv') for n in ('gen3_link_layer','gen3_link_profile','gen3_dllp_source','gen3_replay_tx','gen3_tx_window','gen3_tlp_source','gen3_stp','gen3_recovery_tx','gen3_native_rx','gen3_data_rx','gen3_stream_buffered_rx','gen3_packet_gate')]
files += [CORE/(n+'.sv') for n in ('pcie_soft_flow_control','pcie_soft_requester','pcie_soft_replay','pcie_soft_ack_capture')]
for corrupt in (0,1):
 subprocess.run(['iverilog','-g2012','-s','test_native_link',f'-Ptest_native_link.CORRUPT={corrupt}','-o',str(out/'test'),*map(str,files),str(SRC/'test_native_link.sv')],check=True)
 subprocess.run(['vvp',str(out/'test')],check=True)
print(f'Native end-to-end modeled link: {out}')
