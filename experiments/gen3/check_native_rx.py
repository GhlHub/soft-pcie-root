#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent byte/CRC oracle feeding native PCS RX and retained packet gate."""
from pathlib import Path
import subprocess
import tempfile
import zlib
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'experiments/gen3'
OUT=Path(tempfile.mkdtemp(prefix='gen3_native_rx_',dir=ROOT/'build'))
files=[SRC/(n+'.sv') for n in ('gen3_native_rx','gen3_data_rx','gen3_stream_rx','gen3_stream_buffered_rx','gen3_packet_gate')]
subprocess.run(['verilator','--lint-only','--Wall','--top-module','gen3_native_rx',str(files[0])],check=True)
subprocess.run(['iverilog','-g2012','-s','test_native_rx','-o',str(OUT/'test'),*map(str,files),str(SRC/'test_native_rx.sv')],check=True)
for fault,offset in [(0,x) for x in range(16)]+[(x,(x*3)%16) for x in range(1,9)]:
    state=0x1dbfbc;parity=0;inputs=[]
    def block(raw,header=1,scramble=False,training=False,hold=False):
        global state,parity
        wire=bytearray()
        for i,value in enumerate(raw):
            mask=0
            for bit in range(8):
                mask|=(state>>22)<<bit
                if not hold:state=((state<<1)&0x7fffff)^(0x210125 if state>>22 else 0)
            wire.append(value^mask if scramble or (training and i) else value)
        if header==2:parity^=sum(x.bit_count() for x in wire)&1
        for i in range(0,len(wire),4):
            inputs.append(1<<35|int(i==0)<<34|header<<32|int.from_bytes(wire[i:i+4],'little'))
            # Delivery gaps must neither advance LFSR nor drop framing state.
            if len(inputs)%17==0:inputs.append(0)
    def eieos():
        global state
        block(bytes([0,255])*8);state=0x1dbfbc
    def sds():
        global parity
        block(bytes([0xe1])+bytes([0x55])*15);parity=0
    def skp(length,corrupt=0):
        global parity
        tail=bytes([0xe1,(parity<<7)|(state>>16),(state>>8)&255,state&255])
        raw=bytearray(bytes([0xaa])*(length-4)+tail);raw[-3]^=corrupt
        block(raw,hold=True);parity=0
    eieos()
    block(bytes.fromhex('1e0000200e0021280c004a4a4a4a4a4a'),training=True)
    block(bytes.fromhex('2d0000200e0000454545454545454545'),training=True)
    sds()
    payload=bytes.fromhex('400000017856341200000000efbeadde')
    length=6;crc=sum(((length>>b)&1)<<(14-b) for b in range(11))
    for b in range(14,3,-1):
        if crc>>b&1:crc^=0x13<<(b-4)
    token=bytes([0x6f,((length.bit_count()+crc.bit_count())%2)<<7,crc<<4,0])
    body=bytes.fromhex('78563412');c=0xffff
    for value in body:
        for b in range(8):c=(c>>1)^(0xd008 if (c^(value>>b))&1 else 0)
    packet=bytes(offset)+token+payload+zlib.crc32(bytes(2)+payload).to_bytes(4,'little')
    packet+=bytes.fromhex('f0ac')+body+(c^0xffff).to_bytes(2,'little')
    packet+=bytes((12-len(packet))%16)+bytes.fromhex('1f809000')
    for i in range(0,len(packet),16):block(packet[i:i+16],2,True)
    skp(8)
    block(bytes(16),2,True)
    # All cases first commit the same packet; later corruption must retain it.
    if fault==1:
        block(bytes(16),0)
    elif fault==2:
        skp(16) # missing EDS
    elif fault==3:
        block(bytes(12)+bytes.fromhex('1f809000'),2,True);skp(16,0x80)
    elif fault==4:
        block(bytes(12)+bytes.fromhex('1f809000'),2,True);skp(16,1)
    elif fault==5:
        block(bytes(12)+bytes.fromhex('1f809000'),2,True);block(bytes(16),2,True)
    elif fault==6:
        block(bytes(12)+bytes.fromhex('1f809000'),2,True);eieos();sds();eieos()
    elif fault==7:
        block(bytes(12)+bytes.fromhex('1f809000'),2,True);eieos();sds();block(bytes(16),2,True)
        idx=next(i for i in range(len(inputs)-1,-1,-1) if inputs[i]>>35)
        inputs[idx]|=1<<34 # premature block start
    elif fault==8:
        block(bytes(12)+bytes.fromhex('1f809000'),2,True)
        raw=bytearray(bytes([0xaa])*12+bytes([0xe1,(parity<<7)|(state>>16),(state>>8)&255,state&255]))
        raw[4]=0xab;block(raw,hold=True)
    else:
        for length in (8,12,16,20,24):
            block(bytes(12)+bytes.fromhex('1f809000'),2,True);skp(length);block(bytes(16),2,True)
        block(bytes(12)+bytes.fromhex('1f809000'),2,True);eieos();sds();block(bytes(16),2,True)
    path=OUT/f'{fault}_{offset}.hex';path.write_text(''.join(f'{v:09x}\n' for v in inputs))
    subprocess.run(['vvp',str(OUT/'test'),f'+inputs={path}',f'+count={len(inputs)}',f'+errors={int(fault!=0)}'],check=True)
print(f'Native receive evidence: {OUT}')
