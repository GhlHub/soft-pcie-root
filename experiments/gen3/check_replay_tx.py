#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import subprocess,tempfile,zlib
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'experiments/gen3'
out=Path(tempfile.mkdtemp(prefix='gen3_replay_',dir=ROOT/'build'))
files=[SRC/'gen3_replay_tx.sv',SRC/'gen3_stp.sv']
subprocess.run(['verilator','--lint-only','--Wall',*map(str,files)],check=True)
subprocess.run(['iverilog','-g2012','-s','test_replay_tx','-o',str(out/'test'),*map(str,files),str(SRC/'test_replay_tx.sv')],check=True)
subprocess.run(['vvp',str(out/'test'),f'+OUT={out}/trace.txt'],check=True)
frames={}
for line in (out/'trace.txt').read_text().splitlines():
 frame,index,data=line.split();frames.setdefault(int(frame),[]).append(int(data,16))
for number,words in frames.items():
 assert len(words)==6
 token=words[0];seq=((token>>16)&15)<<8|(token>>24)
 payload=b''.join(w.to_bytes(4,'little') for w in words[1:-1])
 assert words[-1]==zlib.crc32(seq.to_bytes(2,'big')+payload)
 assert ((token>>8)&127)<<4 | ((token>>4)&15)==6
 assert seq==[0,0,1,1,2][number]
assert frames[0]==frames[1] and frames[2]==frames[3]
print(f'PASS: independent zlib LCRC and retained replay bytes; {out}')
