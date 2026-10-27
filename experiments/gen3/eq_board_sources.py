#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
import hashlib
import json
from pathlib import Path
import sys
import shutil
ROOT=Path(__file__).resolve().parents[2]
names=['gen3_eq_board.sv','gen3_eq_bringup.sv','gen3_legacy_training.sv',
       'gen3_startup_ltssm.sv','gen3_training_tx.sv','gen3_training_rx.sv','gen3_recovery_tx.sv','gen3_dllp_source.sv','gen3_link_layer.sv','gen3_replay_tx.sv','gen3_tx_window.sv','gen3_tlp_source.sv','gen3_stp.sv','gen3_native_rx.sv','gen3_data_rx.sv','gen3_stream_rx.sv','gen3_stream_buffered_rx.sv','gen3_packet_gate.sv',
       'gen3_eq_phase1.sv','gen3_clock_watch.sv','build_eq_board.tcl',
       'eq_board_constraints.tcl','audit_ila_config_cdc.tcl','eq_board_sources.py','instrument_eq_phy.py']
files=[ROOT/'experiments/gen3'/n for n in names]+[
    ROOT/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_scrambler.sv',
    ROOT/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_flow_control.sv',
    ROOT/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_requester.sv',
    ROOT/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_replay.sv',
    ROOT/'ip/soft_pcie_root/rtl/pcie_soft/pcie_soft_ack_capture.sv',
    ROOT/'examples/zcu104/constraints/zcu104_fmc.xdc']
manifest={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
mode,path=sys.argv[1:]
if mode=='capture':
    target=Path(path)
    target.write_text(json.dumps(manifest,indent=2)+'\n')
    for name in manifest:
        saved=target.parent/'input_snapshot'/name
        saved.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(ROOT/name,saved)
elif mode=='check':
    if manifest!=json.loads(Path(path).read_text()):raise SystemExit('Build sources changed')
    print('PASS: frozen equalization board sources')
else:raise SystemExit('Expected capture/check and manifest path')
