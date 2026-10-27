#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check on-wire training against an independent byte-level reference."""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'experiments/gen3'
OUT=Path(tempfile.mkdtemp(prefix='gen3_training_',dir=ROOT/'build'))
for module in ('gen3_training_tx','gen3_training_rx'):
    subprocess.run(['verilator','--lint-only','--Wall',str(SRC/f'{module}.sv')],check=True)
for fault in range(2):
    binary=OUT/f'test_{fault}'
    subprocess.run(['iverilog','-g2012','-s','test_training',
        f'-Ptest_training.FAULT={fault}','-o',str(binary),
        *[str(SRC/f'{m}.sv') for m in ('gen3_training_tx','gen3_training_rx','test_training')]],check=True)
    trace=OUT/('trace.txt' if fault==0 else 'corrupt-skp.txt')
    subprocess.run(['vvp',str(binary),f'+OUT={trace}'],check=True)
state=0x1dbfbc
balance=0
block=[]
first=None
ts=eieos=skp=0
since_eieos=0
corrections=set()
for line in (OUT/'trace.txt').read_text().splitlines():
    cycle,valid,start,word,reported=line.split()
    cycle=int(cycle)
    if not int(valid):continue
    if first is None:first=cycle
    assert (cycle-first)%65 !=64
    assert bool(int(start)) == (not block)
    block.extend(int(word,16).to_bytes(4,'little'))
    if len(block)!=16:continue
    raw=bytes(block);block=[]
    if raw[0]==0xaa:
        assert raw[:12]==bytes([0xaa])*12
        assert raw[12:]==bytes([0xe1,((1-(state>>22))<<7)|(state>>16),(state>>8)&255,state&255])
        skp+=1
        continue
    decoded=[]
    after11=None
    for i,value in enumerate(raw):
        mask=0
        for bit in range(8):
            feedback=state>>22
            mask|=feedback<<bit
            state=((state<<1)&0x7fffff)^(0x210125 if feedback else 0)
        decoded.append(value^mask if raw[0]==0x1e and i else value)
        if raw[0]==0x1e:
            balance=max(-511,min(511,balance+2*value.bit_count()-8))
            if i==11:after11=balance
    if raw[0]==0:
        assert raw==bytes([0,255])*8
        assert since_eieos in (0,32)
        since_eieos=0;state=0x1dbfbc;eieos+=1
    elif raw[0]==0x1e:
        assert decoded[:14]==list(bytes.fromhex('1e0000200e0021280c004a4a4a4a'))
        n=2 if abs(after11)>31 else 1 if abs(after11)>15 else 0
        corrections.add(n)
        assert decoded[14]==0x4a if n<2 else raw[14]==(0x20 if after11>0 else 0xdf)
        assert decoded[15]==0x4a if n<1 else raw[15]==(8 if after11>0 else 0xf7)
        ts+=1;since_eieos+=1
    else:assert raw==bytes([0x66])*16
    assert int(reported)==balance
assert ts>=2048 and eieos>60 and skp>=5 and corrections=={0,1,2}
print(f'PASS: independent training wire check: TS1={ts}, EIEOS={eieos}, SKP={skp}; {OUT}')
