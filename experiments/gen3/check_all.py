#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run experimental Gen3 component/integration tests, not link qualification."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--spec", required=True, type=Path, help="local preliminary Base Specification PDF")
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
source=root/"experiments/gen3"
spec=args.spec.resolve(strict=True)
for script in ("check_scrambler.py","check_framing.py","check_rx_blocks.py","check_stp.py",
               "check_stream_rx.py","check_packet_gate.py","check_data_rx.py","check_sequencing.py","check_integration.py",
               "check_equalization.py","check_training.py","check_eq_bringup.py",
               "check_native_rx.py","check_recovery_tx.py","check_recovery_bringup.py",
               "check_replay_tx.py","check_tx_window.py","check_link_layer.py","check_native_link.py"):
    command=[sys.executable,str(source/script)]
    if script=="check_scrambler.py": command.append(str(spec))
    subprocess.run(command,cwd=root,check=True)
for phase in (-1,0,1,63,64):
    subprocess.run([sys.executable,str(source/'check_recovery_tx.py'),
                    '--initfc1','--stop-phase',str(phase)],cwd=root,check=True)
out=Path(tempfile.mkdtemp(prefix="gen3_cadence_",dir=root/"build"))
subprocess.run(["iverilog","-g2012","-s","test_tx_cadence","-o",str(out/"test"),
                str(source/"gen3_tx_cadence.sv"),str(source/"test_tx_cadence.sv")],check=True)
subprocess.run(["vvp",str(out/"test")],check=True)
subprocess.run(["verilator","--lint-only","--Wall",str(source/"gen3_tx_cadence.sv")],check=True)
print("PASS: experimental Gen3 tests. No full-link, routed or physical qualification implied.")
