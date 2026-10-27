#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
import random
from pathlib import Path
import subprocess
import tempfile
import zlib
import sys
word_input="--word-input" in sys.argv

root=Path(__file__).resolve().parents[2]
src=root/"experiments/gen3"
(root/"build").mkdir(exist_ok=True)
out=Path(tempfile.mkdtemp(prefix="gen3_gate_",dir=root/"build"))
rng=random.Random(3)
inputs=[]; expected=[]; words=[]
next_seq=0


def cycle(reset=0,abort=0,start=0,last=0,finish=0,null=0,ready=0,length=0,seq=0,
          body=b"",ack=0,nak=0,error=0,response_seq=0,commit=0):
    value=0
    for val,width in zip((reset,abort,start,last,finish,null,ready,length,seq,len(body),int.from_bytes(body,"little")),
                         (1,1,1,1,1,1,1,11,12,3,32)):
        value=(value<<width)|val
    inputs.append(value)
    expected.append(commit<<15|ack<<14|nak<<13|error<<12|response_seq)


def packet(seq, payload_words=1, four_dw=False, fault=None, null=False, commit=True):
    global next_seq
    # Memory Write header in transmitted byte order; remaining words arbitrary.
    header=bytes([0x60 if four_dw else 0x40,0,(payload_words>>8)&3,payload_words&255])
    tlp=header+bytes(rng.randrange(256) for _ in range((3+int(four_dw)+payload_words)*4-4))
    crc=zlib.crc32(bytes([seq>>8,seq&255])+tlp)
    if null: crc ^= 0xffffffff
    if fault=="crc": crc ^= 1
    raw=tlp+crc.to_bytes(4,"little")
    length=len(raw)//4+1+(fault=="length")
    cycle(start=1,length=length,seq=seq)
    pos=0
    while pos<len(raw):
        n=min(4 if word_input else rng.randrange(1,5),len(raw)-pos)
        cycle(body=raw[pos:pos+n],last=pos+n==len(raw))
        pos+=n
    # Explicit delayed lookahead: no output is legal in these cycles.
    for _ in range(3): cycle()
    reject=fault in ("crc","length","full","future") or payload_words>32
    cycle(finish=1,null=int(null),ack=int(not null),nak=int(reject),error=int(reject),
          response_seq=(next_seq-1)&4095 if reject or seq!=next_seq else seq,
          commit=int(commit and not reject and not null))
    if commit and not reject and not null:
        next_seq+=1
        for p in range(0,len(tlp),4):
            words.append(int(p+4==len(tlp))<<43 | ((payload_words+3)//4)<<32 |
                         int.from_bytes(tlp[p:p+4],"little"))


cycle(reset=1)
packet(0,32,True)
# Restart must preserve the queued packet and its receive sequence.
cycle(abort=1)
packet(1,1)
packet(2,1,fault="full",commit=False)
for _ in range(80): cycle(ready=1)
packet(1,1,commit=False)  # duplicate ACK, no second memory effect
packet(2,1,fault="crc",commit=False)
packet(2,1,fault="length",commit=False)
packet(3,1,fault="future",commit=False)
packet(2,1,null=True,commit=False)
packet(2,33,commit=False)  # MPS128 violation
packet(2,2)
cycle(abort=1)
for _ in range(16): cycle(ready=1)
# Incomplete candidate followed by Recovery must never become visible.
cycle(start=1,length=6,seq=3)
cycle(body=b"\x40\0\0\x01")
cycle(abort=1)
packet(3,1)
for _ in range(16): cycle(ready=1)
(out/"inputs.hex").write_text("".join(f"{v:017x}\n" for v in inputs))
(out/"expected.hex").write_text("".join(f"{v:04x}\n" for v in expected))
(out/"words.hex").write_text("".join(f"{v:011x}\n" for v in words))
subprocess.run(["iverilog","-g2012",f"-Ptest_packet_gate.WORD_INPUT={int(word_input)}","-s","test_packet_gate","-o",str(out/"test"),
                str(src/"gen3_packet_gate.sv"),str(src/"test_packet_gate.sv")],check=True)
subprocess.run(["vvp",str(out/"test"),f"+inputs={out/'inputs.hex'}",f"+expected={out/'expected.hex'}",
                f"+words={out/'words.hex'}",f"+count={len(inputs)}",f"+word_count={len(words)}"],check=True)
subprocess.run(["verilator","--lint-only","--Wall",str(src/"gen3_packet_gate.sv")],check=True)
print(f"Gate results: {out}")

if not word_input:
    subprocess.run([sys.executable,__file__,"--word-input"],check=True)
