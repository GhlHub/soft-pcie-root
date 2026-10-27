#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import subprocess,tempfile,zlib
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'experiments/gen3';CORE=ROOT/'ip/soft_pcie_root/rtl/pcie_soft'
out=Path(tempfile.mkdtemp(prefix='gen3_link_layer_',dir=ROOT/'build'))
files=[SRC/(n+'.sv') for n in ('gen3_link_layer','gen3_link_profile','gen3_dllp_source','gen3_replay_tx','gen3_tx_window','gen3_tlp_source','gen3_stp')]
files += [CORE/(n+'.sv') for n in ('pcie_soft_flow_control','pcie_soft_requester','pcie_soft_replay','pcie_soft_ack_capture')]
subprocess.run(['verilator','--lint-only','--Wall','--top-module','gen3_link_layer',*map(str,files)],check=True)
subprocess.run(['iverilog','-g2012','-s','test_link_layer','-o',str(out/'test'),*map(str,files),str(SRC/'test_link_layer.sv')],check=True)
subprocess.run(['vvp',str(out/'test'),f'+OUT={out}/trace.txt'],check=True)
frames={}
for line in (out/'trace.txt').read_text().splitlines():
 f,i,d,last=line.split();frames.setdefault(int(f),[]).append(int(d,16))
types=[];tlps=[]
for words in frames.values():
 data=b''.join(w.to_bytes(4,'little') for w in words)
 if data[:2]==bytes.fromhex('f0ac'):
  assert len(data)==8
  c=0xffff
  for byte in data[2:6]:
   for b in range(8):c=(c>>1)^(0xd008 if (c^(byte>>b))&1 else 0)
  assert int.from_bytes(data[6:],'little')==((~c)&0xffff)
  types.append(data[2])
 else:
  token=words[0];seq=((token>>16)&15)<<8|(token>>24)
  assert words[-1]==zlib.crc32(seq.to_bytes(2,'big')+data[4:-4])
  tlps.append(words)
assert len(tlps)==2 and len(tlps[0])==5 and len(tlps[1])==37
assert tlps[0][1:4]==[0x01000004,0x0f000000,0x00000001]
assert all(t in types for t in (0x40,0x50,0x60,0xc0,0xd0,0xe0,0))
print(f'PASS: independent config header, TLP LCRC and DLLP CRC/order checks; {out}')
