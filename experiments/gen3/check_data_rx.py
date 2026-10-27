#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import random
import subprocess
import tempfile
import zlib

root=Path(__file__).resolve().parents[2]
src=root/"experiments/gen3"
(root/"build").mkdir(exist_ok=True)
out=Path(tempfile.mkdtemp(prefix="gen3_data_rx_",dir=root/"build"))
rng=random.Random(40)
stream=bytearray(); words=[]


def stp(length,seq):
    crc=sum(((length>>b)&1)<<(14-b) for b in range(11))
    for p in range(14,3,-1):
        if crc & (1<<p): crc ^= 0x13<<(p-4)
    parity=(length.bit_count()+crc.bit_count())&1
    return bytes([((length&15)<<4)|15,(length>>4)|(parity<<7),(crc<<4)|(seq>>8),seq&255])


def dllp():
    body=bytes.fromhex("78563412")
    c=0xffff
    for octet in body:
        for b in range(8): c=(c>>1)^(0xd008 if (c^(octet>>b))&1 else 0)
    return bytes([0xf0,0xac])+body+(c^0xffff).to_bytes(2,"little")


for seq in range(40):
    n=(1,2,31,32)[seq%4]; four_dw=seq%2
    payload=bytes([0x60 if four_dw else 0x40,0,0,n])
    payload+=bytes(rng.randrange(256) for _ in range((3+four_dw+n)*4-4))
    # No padding between most TLPs: deferred finish can coincide with next STP.
    if seq%4==0: stream+=bytes(seq%3)
    stream+=stp(len(payload)//4+2,seq)+payload
    stream+=zlib.crc32(bytes([seq>>8,seq&255])+payload).to_bytes(4,"little")
    if seq%2: stream+=dllp()*2
    for p in range(0,len(payload),4):
        words.append(int(p+4==len(payload))<<43|((n+3)//4)<<32|int.from_bytes(payload[p:p+4],"little"))
stream+=bytes((12-len(stream))%16)+bytes.fromhex("1f809000")
inputs=[1<<37,1<<35]
for pos in range(0,len(stream),4):
    inputs.append(1<<34|((pos//4)%4)<<32|int.from_bytes(stream[pos:pos+4],"little"))
    if pos%76==0: inputs.append(0)
(out/"inputs.hex").write_text("".join(f"{v:010x}\n" for v in inputs))
(out/"words.hex").write_text("".join(f"{v:011x}\n" for v in words))
files=["gen3_data_rx.sv","gen3_stream_rx.sv","gen3_stream_buffered_rx.sv","gen3_packet_gate.sv"]
subprocess.run(["iverilog","-g2012","-s","test_data_rx","-o",str(out/"test"),
                *(str(src/f) for f in files),str(src/"test_data_rx.sv")],check=True)
subprocess.run(["vvp",str(out/"test"),f"+inputs={out/'inputs.hex'}",f"+words={out/'words.hex'}",
                f"+count={len(inputs)}",f"+word_count={len(words)}"],check=True)
subprocess.run(["verilator","--lint-only","--Wall","--top-module","gen3_data_rx",
                *(str(src/f) for f in files)],check=True)
print(f"Integrated RX results: {out}")
