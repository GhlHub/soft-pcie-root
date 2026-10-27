#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build independent serialized stimuli with events at known block boundaries."""
from pathlib import Path
import random
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / "experiments/gen3"
(root / "build").mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix="gen3_rx_", dir=root / "build"))
rng = random.Random(130)
eieos = bytes([0, 255]*8)
sds = bytes([0xe1]+[0x55]*15)
inputs, expected = [], []


def wire(header, payload):
    return [header & 1, header >> 1] + [(b >> n) & 1 for b in payload for n in range(8)]


class Stream:
    def __init__(self, offset):
        self.bits = [0]*offset
        self.events = {}
        self.lock = False

    def block(self, header, payload):
        self.bits += wire(header, payload)
        if payload == sds and header == 1:
            self.lock = True
        self.events[len(self.bits)-1] = (1, int(self.lock), 0, header, payload)

    def fault(self, bits):
        self.bits += bits
        self.events[len(self.bits)-1] = (0, 0, 1, None, b"")
        self.lock = False

    def finish(self):
        inputs.append(1 << 32)
        expected.append(0)
        # Complete padding is not a new header: caller ends in unaligned state.
        self.bits += [0]*((-len(self.bits)) % 32)
        aligned = locked = 0
        for start in range(0, len(self.bits), 32):
            emit = err = length = hdr = value = 0
            for pos in range(start, start+32):
                if pos in self.events:
                    aligned, locked, error, header, payload = self.events[pos]
                    err |= error
                    if header is not None:
                        assert not emit, "test requires at most one block per input word"
                        emit = 1
                        hdr, length = header, len(payload)
                        value = int.from_bytes(payload, "little")
            inputs.append((1 << 33) | sum(b << i for i, b in enumerate(self.bits[start:start+32])))
            expected.append((aligned << 202) | (locked << 201) | (err << 200) |
                            (emit << 199) | (length << 194) | (hdr << 192) | value)
            if start % 96 == 0:
                inputs.append(0)
                expected.append((aligned << 202) | (locked << 201))
        inputs.append(0)
        expected.append((aligned << 202) | (locked << 201))


for offset in range(32):
    st = Stream(offset)
    st.block(1, eieos)
    st.block(1, bytes([0x1e]+[0x33]*15))
    st.block(1, sds)
    st.block(2, bytes(rng.randrange(256) for _ in range(16)))
    # Embed an entire EIEOS across two Data Blocks, including their intervening
    # header. That header's transmitted 0,1 bits match pattern bits 9,10.
    pattern = wire(1, eieos)
    assert pattern[9:11] == [0, 1]
    first = [0]*119 + pattern[:9]
    second = pattern[11:] + [0]*9
    def octets(bits):
        return bytes(sum(bit << n for n, bit in enumerate(bits[i:i+8]))
                     for i in range(0, len(bits), 8))
    st.block(2, octets(first))
    st.block(2, octets(second))
    for symbols in (8, 12, 16, 20, 24):
        st.block(1, bytes([0xaa]*(symbols-4)+[0xe1,0x12,0x34,0x56]))
        st.block(2, bytes(rng.randrange(256) for _ in range(16)))
    st.fault([offset & 1]*2)  # both illegal headers lose lock
    st.bits += [0]*37
    st.block(1, eieos)
    st.block(1, sds)
    st.fault([1, 0])  # SDS must be followed by a data header, not an OS
    st.finish()

for offset in range(32):
    st = Stream(offset)
    st.block(1, eieos)
    st.fault([offset & 1]*2)
    st.finish()

# Reacquire a shifted EIEOS while Aligned, before SDS locks the stream.
for offset in range(32):
    st = Stream(offset)
    st.block(1, eieos)
    start = len(st.bits)
    shifted = [0, 1, 0, 0, 0] + wire(1, eieos)
    st.bits += shifted
    old_end, anchor_end = start+129, start+134
    # Acquisition supersedes a tentative block completed in the same word.
    if old_end//32 != anchor_end//32:
        payload_bits = shifted[2:130]
        tentative = bytes(sum(bit << n for n, bit in enumerate(payload_bits[i:i+8]))
                          for i in range(0, 128, 8))
        st.events[old_end] = (1, 0, 0, 2, tentative)
        if (old_end+2)//32 != anchor_end//32:
            st.events[old_end+2] = (0, 0, 1, None, b"")
    st.events[anchor_end] = (1, 0, 0, 1, eieos)
    st.block(1, sds)
    st.block(2, bytes(16))
    st.fault([0, 0])
    st.finish()

for index in (1, 3, 5, 7, 9, 19, 20):
    st = Stream(index)
    st.block(1, eieos)
    st.block(1, sds)
    st.block(2, bytes(16))
    # Invalid SKP_END position, or missing SKP_END at maximum length.
    malformed = bytes([0xaa]*index + [0xaa if index == 20 else 0xe1])
    st.fault(wire(1, malformed))
    st.finish()

(work / "inputs.hex").write_text("".join(f"{v:09x}\n" for v in inputs))
(work / "expected.hex").write_text("".join(f"{v:051x}\n" for v in expected))
subprocess.run(["iverilog", "-g2012", "-s", "test_rx_blocks", "-o", str(work/"test"),
                str(source/"gen3_eieos_detect.sv"), str(source/"gen3_rx_blocks.sv"), str(source/"test_rx_blocks.sv")], check=True)
subprocess.run(["vvp", str(work/"test"), f"+inputs={work/'inputs.hex'}",
                f"+expected={work/'expected.hex'}", f"+size={len(inputs)}"], check=True)
subprocess.run(["verilator", "--lint-only", "--Wall", str(source/"gen3_rx_blocks.sv"), str(source/"gen3_eieos_detect.sv")], check=True)
print(f"RX results: {work}")
