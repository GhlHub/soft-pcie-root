#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent wire-bit scoreboards for experimental Gen3 framing components."""
from pathlib import Path
import random
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / "experiments/gen3"
(root / "build").mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix="gen3_framing_", dir=root / "build"))
rng = random.Random(0x130)
# Construct in transmitted order from symbol values, independently of RTL
# packed-vector notation. Header is 01b, transmitted low bit first.
pattern = [1, 0]
for symbol in [0x00, 0xff] * 8:
    pattern.extend((symbol >> bit) & 1 for bit in range(8))
records = []


def trial(bits, search=True, interrupt=None):
    records.append(1 << 39)  # synchronous reset; stale history must not match
    history = []
    bits += [rng.randrange(2) for _ in range((-len(bits)) % 32)]
    for start in range(0, len(bits), 32):
        word = bits[start:start+32]
        reset = start == interrupt
        match = None
        if reset:
            history = []
        else:
            for end, bit in enumerate(word):
                history.append(bit)
                if search and history[-130:] == pattern:
                    match = end
        value = sum(bit << n for n, bit in enumerate(word))
        value |= int(search) << 38 | int(reset) << 39
        if match is not None:
            value |= 1 << 37 | match << 32
        records.append(value)


for offset in range(32):
    prefix = [rng.randrange(2) for _ in range(offset)]
    trial(prefix + pattern + pattern + [0]*64)
    trial(prefix + pattern + [0]*64, search=False)
    trial(prefix + pattern + [0]*64, interrupt=64)
for corrupt in range(130):
    damaged = pattern.copy()
    damaged[corrupt] ^= 1
    trial([0]*17 + damaged + [0]*64)
trial([rng.randrange(2) for _ in range(32000)])
(work / "vectors.hex").write_text("".join(f"{v:010x}\n" for v in records))
for name, files, args in [
    ("test_tx_gearbox", ["gen3_tx_gearbox.sv", "test_tx_gearbox.sv"], []),
    ("test_eieos", ["gen3_eieos_detect.sv", "test_eieos.sv"],
     [f"+vectors={work / 'vectors.hex'}", f"+size={len(records)}"]),
]:
    subprocess.run(["iverilog", "-g2012", "-s", name, "-o", str(work/name),
                    *(str(source/f) for f in files)], check=True)
    subprocess.run(["vvp", str(work/name), *args], check=True)
    subprocess.run(["verilator", "--lint-only", "--Wall", str(source/files[0])], check=True)
print(f"Framing results: {work}")
