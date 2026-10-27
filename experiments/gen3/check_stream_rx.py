#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Serialize independent framing scenarios; expected events use byte positions."""
from pathlib import Path
import random
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = root / "experiments/gen3"
(root/"build").mkdir(exist_ok=True)
out = Path(tempfile.mkdtemp(prefix="gen3_stream_", dir=root/"build"))
rng = random.Random(3)
inputs, expected = [], []


def encode(length, seq):
    crc = sum(((length >> b) & 1) << (14-b) for b in range(11))
    for p in range(14, 3, -1):
        if crc & 1 << p:
            crc ^= 0x13 << (p-4)
    parity = (length.bit_count()+crc.bit_count()) & 1
    return bytes([(length & 15)*16+15, (length >> 4)+128*parity,
                  crc*16+(seq >> 8), seq & 255])


def pack(active, error=0, eds=0, start=0, length=0, seq=0, body=0, n=0,
         last=0, finish=0, null=0, dllp=0, dllp_bytes=0):
    value = 0
    for v, width in zip((active,error,eds,start,length,seq,body,n,last,finish,null,dllp,dllp_bytes),
                        (1,1,1,1,11,12,32,3,1,1,1,1,48)):
        value = (value << width) | v
    return value


def case(offset, length=6, null=False, corrupt=None):
    data = bytearray(offset)
    events = {}
    body_positions = {}
    seq = rng.randrange(4096)
    token = bytearray(encode(length, seq))
    if corrupt == "stp": token[2] ^= 0x10
    data += token
    if corrupt == "stp": events[len(data)-1] = {"error":1}
    else: events[len(data)-1] = {"start":1,"length":length,"seq":seq}
    for _ in range((length-1)*4):
        body_positions[len(data)] = rng.randrange(256)
        data.append(body_positions[len(data)])
    events[len(data)-1] = {"last":1}
    if null:
        data += bytes([0xc0]*4)
        if corrupt == "edb":
            data[-1] = 0xc1
            events[len(data)-1] = {"error":1}
        else: events[len(data)-1] = {"finish":1,"null":1}
    else:
        events[len(data)] = {"finish":1}
        data.append(0)
    # DLLP checksum bytes are deliberately opaque to this framing layer.
    dllp = bytes(rng.randrange(256) for _ in range(6))
    data += bytes([0xf0, 0xac]) + dllp
    events[len(data)-1] = {"dllp":1,"dllp_bytes":int.from_bytes(dllp,"little")}
    if corrupt == "sdp":
        pos = len(data)-7
        data[pos] = 0xad
        events[pos] = {"error":1}
    if corrupt == "orphan_edb":
        events[len(data)] = {"error":1}
        data += bytes([0xc0]*4)
    data += bytes((12-len(data)) % 16)
    if corrupt == "eds": data += bytes(16)
    data += bytes([0x1f,0x80,0x90,0])
    events[len(data)-1] = {"eds":1}
    if corrupt == "eds":
        # Shift EDS one symbol early. Its four bytes remain complete.
        del data[-5]
        events.pop(len(data))
        events[len(data)-1] = {"error":1}
        data.append(0)
    inputs.append(1 << 35)  # SDS/start pulse, no data on the same edge
    expected.append(pack(1))
    active = 1
    for pos in range(0, len(data), 4):
        flags = {}
        body = []
        for p in range(pos, pos+4):
            if active:
                if p in body_positions: body.append(body_positions[p])
                flags.update(events.get(p, {}))
                if flags.get("error") or flags.get("eds"): active = 0
        if flags.get("error"):
            flags = {"error":1}
            body = []
        flags.update(body=int.from_bytes(bytes(body),"little"), n=len(body))
        inputs.append((1 << 34) | ((pos//4)%4 << 32) | int.from_bytes(data[pos:pos+4],"little"))
        expected.append(pack(active, **flags))
        if pos % 12 == 0:
            inputs.append(0)
            expected.append(pack(active))
    inputs.append(1 << 36)  # Abort invalidates framing only
    expected.append(pack(0))


inputs.append(1 << 37); expected.append(pack(0))
for offset in range(16):
    for length in (5, 6, 35, 36):
        case(offset, length)
        case(offset, length, null=True)
    for fault in ("stp", "edb", "sdp", "orphan_edb", "eds"):
        case(offset, null=(fault=="edb"), corrupt=fault)
(out/"inputs.hex").write_text("".join(f"{v:010x}\n" for v in inputs))
(out/"expected.hex").write_text("".join(f"{v:029x}\n" for v in expected))
subprocess.run(["iverilog","-g2012","-s","test_stream_rx","-o",str(out/"test"),
                str(src/"gen3_stream_rx.sv"),str(src/"test_stream_rx.sv")],check=True)
subprocess.run(["vvp",str(out/"test"),f"+inputs={out/'inputs.hex'}",
                f"+expected={out/'expected.hex'}",f"+count={len(inputs)}"],check=True)
subprocess.run(["verilator","--lint-only","--Wall",str(src/"gen3_stream_rx.sv")],check=True)
print(f"Stream results: {out}")

# Compare semantic events, allowing the buffered parser's latency and aligned
# DWORD body output. Error cases must quarantine once; provisional chunks are
# not a packet-commit oracle.
checks=[]; summary=None
for inp,exp in zip(inputs,expected):
    if inp & (1<<35):
        summary=dict(starts=0,lasts=0,finishes=0,nulls=0,dllps=0,ends=0,n=0,h=0,stp=0,dllp=0,error=0)
    if summary is not None:
        widths=(1,1,1,1,11,12,32,3,1,1,1,1,48)
        fields=[];tmp=exp
        for width in reversed(widths):fields.append(tmp&((1<<width)-1));tmp>>=width
        _,error,eds,start,length,seq,body,n,last,finish,null,dllp,dbytes=reversed(fields)
        summary['error']|=error
        if start:summary['starts']+=1;summary['stp']=(length<<12)|seq
        for octet in body.to_bytes(4,'little')[:n]:summary['h']=(summary['h']*33+octet)&0xffffffff
        summary['n']+=n;summary['lasts']+=last;summary['finishes']+=finish
        summary['nulls']+=finish and null;summary['ends']+=eds
        if dllp:summary['dllps']+=1;summary['dllp']=dbytes
        if inp & (1<<36):
            value=0
            for key,width in zip(('starts','lasts','finishes','nulls','dllps','ends','n','h','stp','dllp','error'),(8,8,8,8,8,8,16,32,23,48,1)):
                value=(value<<width)|summary[key]
            checks.append(value);summary=None
(out/'buffered.hex').write_text(''.join(f'{v:048x}\n' for v in checks))
subprocess.run(['iverilog','-g2012','-s','test_stream_buffered_rx','-o',str(out/'buffered'),
                str(src/'gen3_stream_buffered_rx.sv'),str(src/'test_stream_buffered_rx.sv')],check=True)
subprocess.run(['vvp',str(out/'buffered'),f'+inputs={out}/inputs.hex',f'+expected={out}/buffered.hex',
                f'+count={len(inputs)}',f'+cases={len(checks)}'],check=True)
subprocess.run(['verilator','--lint-only','--Wall',str(src/'gen3_stream_buffered_rx.sv')],check=True)
