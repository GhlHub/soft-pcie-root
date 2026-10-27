#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Gen2-capacity Gen3 transport, including independent wire-frame CRC checks."""
from pathlib import Path
import subprocess,tempfile,zlib
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'experiments/gen3';CORE=ROOT/'ip/soft_pcie_root/rtl/pcie_soft'
out=Path(tempfile.mkdtemp(prefix='gen3_tx_window_',dir=ROOT/'build'))
files=[SRC/(n+'.sv') for n in ('gen3_tx_window','gen3_tlp_source','gen3_stp')]
files += [CORE/(n+'.sv') for n in ('pcie_soft_replay','pcie_soft_ack_capture')]
subprocess.run(['verilator','--lint-only','--Wall','--top-module','gen3_tx_window',*map(str,files)],check=True)
subprocess.run(['iverilog','-g2012','-s','test_tx_window','-o',str(out/'test'),*map(str,files),str(SRC/'test_tx_window.sv')],check=True)
subprocess.run(['vvp',str(out/'test'),f'+OUT={out}/trace.txt'],check=True)
frames={}
for line in (out/'trace.txt').read_text().splitlines():
 f,i,d=line.split();frames.setdefault(int(f),[]).append(int(d,16))
for words in frames.values():
 assert len(words)==6
 token=words[0];seq=((token>>16)&15)<<8|(token>>24)
 assert words[1:5]==[0xa5000000+seq*4+j for j in range(4)]
 payload=b''.join(w.to_bytes(4,'little') for w in words[1:-1])
 assert words[-1]==zlib.crc32(seq.to_bytes(2,'big')+payload)
 assert (((token>>8)&127)<<4)|((token>>4)&15)==6
print(f'PASS: {len(frames)} independently checked framed packets including replay and sequence wrap; {out}')
