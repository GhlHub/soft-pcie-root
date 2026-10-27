#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Use pinned, unmodified cocotbext-pcie DLLP encoding as an independent oracle.

Upstream MIT sources stay in a separately fetched checkout. This runner does
not copy upstream code into the released RTL or require the cocotb runtime.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'experiments/gen3'
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source',required=True,type=Path,help='pinned cocotbext-pcie checkout')
args=parser.parse_args()
checkout=args.source.resolve(strict=True)
lock=json.loads((SRC/'open_source_oracles.lock.json').read_text())['cocotbext-pcie']
actual=subprocess.check_output(['git','-C',str(checkout),'rev-parse','HEAD'],text=True).strip()
if actual!=lock['commit']:
    raise SystemExit(f'Expected upstream commit {lock["commit"]}, got {actual}')
module_path=checkout/lock['file']
if hashlib.sha256(module_path.read_bytes()).hexdigest()!=lock['sha256']:
    raise SystemExit('Upstream oracle file differs from the reviewed version')
spec=importlib.util.spec_from_file_location('external_dllp_oracle',module_path)
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
out=Path(tempfile.mkdtemp(prefix='gen3_dllp_oracle_',dir=ROOT/'build'))
types=[module.DllpType.ACK,module.DllpType.NAK,*module.dllp_type_fc_type_mapping]
cases=[]
for offset in range(16):
    for number,kind in enumerate(types):
        packet=module.Dllp()
        packet.type=kind
        if kind in (module.DllpType.ACK,module.DllpType.NAK):
            packet.seq=(0,1,0x7ff,0xfff)[offset%4]
        else:
            packet.hdr_fc=(offset*19+number*7)&255
            packet.data_fc=(offset*257+number*29)&4095
        # VC0, unscaled credits match the current project's support.
        encoded=packet.pack_crc()
        assert module.Dllp.unpack_crc(encoded)==packet
        for corrupt in range(-1,48):
            payload=bytearray(encoded)
            if corrupt>=0:payload[corrupt//8]^=1<<(corrupt%8)
            stream=bytes(offset)+bytes.fromhex('f0ac')+payload
            stream+=bytes((-len(stream))%16)
            expected=int.from_bytes(encoded[:4],'little')
            case=int.from_bytes(stream,'little') | expected<<256 | (len(stream)//4)<<288
            case|=int(corrupt>=0)<<292
            cases.append(case)
(out/'cases.hex').write_text(''.join(f'{case:074x}\n' for case in cases))
files=[SRC/name for name in ('gen3_data_rx.sv','gen3_stream_rx.sv','gen3_packet_gate.sv')]
subprocess.run(['iverilog','-g2012','-s','test_dllp_oracle','-o',str(out/'test'),
                *map(str,files),str(SRC/'test_dllp_oracle.sv')],check=True)
subprocess.run(['vvp',str(out/'test'),f'+cases={out/"cases.hex"}',f'+count={len(cases)}'],check=True)
(out/'oracle.json').write_text(json.dumps({'source':lock,'cases':len(cases),
    'valid':len(types)*16,'corrupted':len(types)*16*48,'result':'pass'},indent=2)+'\n')
print(f'Independent oracle results: {out}')
