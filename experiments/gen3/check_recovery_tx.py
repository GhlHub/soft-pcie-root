#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent wire decoder: continuous training-to-data scrambling and cadence."""
from pathlib import Path
import subprocess
import tempfile
import argparse
parser=argparse.ArgumentParser()
parser.add_argument("--initfc1",action="store_true")
parser.add_argument("--stop-phase",type=int,default=-1)
args=parser.parse_args()
ROOT=Path(__file__).resolve().parents[2];SRC=ROOT/'experiments/gen3'
OUT=Path(tempfile.mkdtemp(prefix='gen3_recovery_tx_',dir=ROOT/'build'))
subprocess.run(['verilator','--lint-only','--Wall',str(SRC/'gen3_recovery_tx.sv')],check=True)
subprocess.run(['iverilog','-g2012','-s','test_recovery_tx',f'-Ptest_recovery_tx.INITFC1={int(args.initfc1)}',f'-Ptest_recovery_tx.STOP_PHASE={args.stop_phase}','-o',str(OUT/'test'),str(SRC/'gen3_recovery_tx.sv'),str(SRC/'test_recovery_tx.sv')],check=True)
subprocess.run(['vvp',str(OUT/'test'),f'+OUT={OUT}/trace.txt'],check=True)
state=0x1dbfbc;parity=0;block=[];first=None;stream=False;closed=False;balance=0
fc_packets=[];fc_cycles=[]
counts=dict(ts1=0,ts2=0,sds=0,data=0,skp=0,eios=0)
for line in (OUT/'trace.txt').read_text().splitlines():
    cycle,valid,start,header,word=line.split();cycle=int(cycle);header=int(header)
    if not int(valid):continue
    if first is None:first=cycle
    assert (cycle-first)%65!=64
    assert bool(int(start))== (not block)
    if not block:block_header=header
    assert header==block_header
    block.extend(int(word,16).to_bytes(4,'little'))
    if len(block)!=16:continue
    raw=bytes(block);block=[]
    if header==1 and raw[0]==0xaa:
        assert raw[:12]==bytes([0xaa])*12
        assert raw[12:]==bytes([0xe1,((parity if stream else 1-(state>>22))<<7)|(state>>16),(state>>8)&255,state&255])
        assert not stream or closed
        parity=0;closed=False;counts['skp']+=1;continue
    decoded=[]
    for i,value in enumerate(raw):
        mask=0
        for bit in range(8):
            feedback=state>>22;mask|=feedback<<bit
            state=((state<<1)&0x7fffff)^(0x210125 if feedback else 0)
        decoded.append(value^mask if header==2 or (raw[0] in (0x1e,0x2d) and i) else value)
        if header==1 and raw[0] in (0x1e,0x2d):balance=max(-511,min(511,balance+2*value.bit_count()-8))
    if header==2:
        assert stream and not closed
        if decoded[:2]==[0xf0,0xac]:
            assert args.initfc1 and decoded[8:]==[0]*8
            fc_packets.append(bytes(decoded[2:8]));fc_cycles.append(cycle)
        else:assert bytes(decoded) in (bytes(16),bytes(12)+bytes.fromhex('1f809000'))
        closed=decoded[-4:]!=[0]*4
        parity^=sum(v.bit_count() for v in raw)&1;counts['data']+=1
    elif raw[0]==0:
        assert not stream and raw==bytes([0,255])*8;state=0x1dbfbc
    elif raw[0] in (0x1e,0x2d):
        assert not stream
        if raw[0]==0x1e:
            assert decoded[:14]==list(bytes.fromhex('1e0000200e00200028804a4a4a4a'));counts['ts1']+=1
        else:
            assert decoded[:14]==list(bytes.fromhex('2d0000200e000045454545454545'));counts['ts2']+=1
    elif raw[0]==0xe1:
        assert not stream and raw==bytes([0xe1])+bytes([0x55])*15
        stream=True;parity=0;counts['sds']+=1
    else:
        assert raw==bytes([0x66])*16 and closed
        stream=False;counts['eios']+=1
assert counts['ts1']>=40 and counts['ts2']>=40 and counts['sds']==1 and counts['skp']>=5 and counts['eios']==1
print(f'PASS: independent Recovery TX oracle {counts}; {OUT}')

if args.initfc1:
    # Independent byte-wise CRC formulation (left-shifting bit-reversed state).
    def crc(data):
        c=0xffff
        for byte in data:
            for bit in range(8):
                feedback=((c>>15)^((byte>>bit)&1))&1
                c=((c<<1)&0xffff)^(0x100b if feedback else 0)
        return ((~int(f'{c:016b}'[::-1],2))&0xffff).to_bytes(2,'little')
    bodies=[bytes.fromhex(x) for x in ('40004008','50004001','60000000')]
    expected=[b+crc(b) for b in bodies]
    assert len(fc_packets)>=9
    assert all(packet==expected[i%3] for i,packet in enumerate(fc_packets))
    assert all(1024<=b-a<=1040 for a,b in zip(fc_cycles,fc_cycles[1:]))
    assert all(b-a<8500 for a,b in zip(fc_cycles,fc_cycles[3:]))
    (OUT/'initfc1.hex').write_text('\n'.join(p.hex() for p in expected)+'\n')
    print(f'PASS: {len(fc_packets)} ordered InitFC1 packets, CRC, spacing, atomic stop phase {args.stop_phase}')
else:assert not fc_packets
